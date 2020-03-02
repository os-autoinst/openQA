# Copyright (C) 2016-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::BuildResults;

use strict;
use warnings;

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils;
use Date::Format;
use Sort::Versions;

sub init_job_figures {
    my ($job_result) = @_;

    # relevant distributions for the build (hash is used as a set)
    $job_result->{distris} = {};

    # number of passed/failed/... jobs
    $job_result->{passed}     = 0;
    $job_result->{failed}     = 0;
    $job_result->{unfinished} = 0;
    $job_result->{labeled}    = 0;
    $job_result->{softfailed} = 0;
    $job_result->{skipped}    = 0;
    $job_result->{total}      = 0;
}

sub count_job {
    my ($job, $jr, $labels) = @_;

    $jr->{total}++;
    if ($job->state eq OpenQA::Jobs::Constants::DONE) {
        if ($job->result eq OpenQA::Jobs::Constants::PASSED) {
            $jr->{passed}++;
            return;
        }
        if ($job->result eq OpenQA::Jobs::Constants::SOFTFAILED) {
            $jr->{softfailed}++;
            return;
        }
        if (grep { $job->result eq $_ } OpenQA::Jobs::Constants::ABORTED_RESULTS) {
            $jr->{skipped}++;
            return;
        }
        if (grep { $job->result eq $_ } OpenQA::Jobs::Constants::NOT_OK_RESULTS) {
            $jr->{failed}++;
            $jr->{labeled}++ if $labels->{$job->id};
            return;
        }
        # note: Incompletes and timeouts are accounted to both categories - failed and skipped.
    }
    if ($job->state eq OpenQA::Jobs::Constants::CANCELLED) {
        $jr->{skipped}++;
        return;
    }
    my $state = $job->state;
    if (grep { /$state/ } (OpenQA::Jobs::Constants::PENDING_STATES)) {
        $jr->{unfinished}++;
        return;
    }
    log_error("MISSING S:" . $job->state . " R:" . $job->result);
    return;
}

sub add_review_badge {
    my ($build_res) = @_;

    $build_res->{all_passed} = $build_res->{passed} + $build_res->{softfailed} >= $build_res->{total};
    $build_res->{reviewed}   = $build_res->{labeled} >= $build_res->{failed};
}

sub filter_subgroups {
    my ($group, $subgroup_filter) = @_;

    my @group_ids;
    my @children;
    my $group_name = $group->name;

    for my $child ($group->children) {
        my $full_name = $child->full_name;
        if (grep { $_ eq '' || $full_name =~ /$_/ } @$subgroup_filter) {
            push(@group_ids, $child->id);
            push(@children,  $child);
        }
    }
    return {
        group_ids => \@group_ids,
        children  => \@children,
    };
}

sub find_child_groups {
    my ($group, $subgroup_filter) = @_;

    # handle regular (non-parent) groups
    return {
        group_ids => [$group->id],
        children  => [],
    } unless $group->can('children');

    # handle simple case where no filter for subgroups present
    return {
        group_ids => $group->child_group_ids,
        children  => [$group->children],
    } unless @$subgroup_filter;

    return filter_subgroups($group, $subgroup_filter);
}

sub compute_build_results {
    my ($group, $limit, $time_limit_days, $tags, $subgroup_filter) = @_;

    # find relevant child groups taking filter into account
    my $child_groups = find_child_groups($group, $subgroup_filter);
    my $group_ids    = $child_groups->{group_ids};
    my $children     = $child_groups->{children};

    my @sorted_results;
    my %result = (
        build_results => \@sorted_results,
        max_jobs      => 0,
        children      => [map { {id => $_->id, name => $_->name} } @$children],
        group         => {
            id   => $group->id,
            name => $group->name
        });

    if (defined($limit) && int($limit) <= 0) {
        return \%result;
    }

    # 400 is the max. limit selectable in the group overview
    my $row_limit   = (defined($limit) && $limit > 400) ? $limit : 400;
    my @search_cols = qw(VERSION BUILD);
    my %search_opts = (
        select   => [@search_cols, {max => 'id', -as => 'lasted_job'}],
        group_by => \@search_cols,
        order_by => {-desc => 'lasted_job'},
        rows     => $row_limit
    );
    my %search_filter = (group_id => {in => $group_ids});
    if ($time_limit_days) {
        $search_filter{t_created}
          = {'>' => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * $time_limit_days, 'UTC')};
    }

    # add search filter for tags
    # caveat: a tag that references only a build, not including a version, might be ambiguous
    if ($tags) {
        my @builds;
        my @versions;
        for my $tag_id (keys %$tags) {
            my $tag = $tags->{$tag_id};
            push(@builds,   $tag->{build})   if $tag->{build};
            push(@versions, $tag->{version}) if $tag->{version};
        }
        $search_filter{BUILD}   = {-in => \@builds};
        $search_filter{VERSION} = {-in => \@versions} if @versions;
    }

    # find relevant builds
    my $jobs_resultset = $group->result_source->schema->resultset('Jobs');
    my @builds         = $jobs_resultset->search(\%search_filter, \%search_opts)->all;
    for my $build (@builds) {
        $build->{key} = join('-', $build->VERSION, $build->BUILD);
    }
    # sort by treating the key as a version number, if job group
    # indicates this is OK (the default). otherwise, list remains
    # sorted on the most recent job for each build
    my $versort = 1;
    $versort = $group->build_version_sort if $group->can('build_version_sort');
    if ($versort) {
        @builds = reverse sort { versioncmp($a->{key}, $b->{key}); } @builds;
    }

    my $max_jobs = 0;
    my $buildnr  = 0;
    for my $build (@builds) {
        last if defined($limit) && (--$limit < 0);

        my $jobs = $jobs_resultset->search(
            {
                VERSION  => $build->VERSION,
                BUILD    => $build->BUILD,
                group_id => {in => $group_ids},
                clone_id => undef,
            },
            {order_by => 'me.id DESC'});
        my %jr = (
            key     => $build->{key},
            build   => $build->BUILD,
            version => $build->VERSION,
            oldest  => DateTime->now
        );
        init_job_figures(\%jr);
        for my $child (@$children) {
            init_job_figures($jr{children}->{$child->id} = {});
        }

        my %seen;
        my @ids = map { $_->id } $jobs->all;
        # prefetch comments to count. Any comment is considered a label here
        # so a build is considered as 'reviewed' if all failures have at least
        # a comment. This could be improved to distinguish between
        # "only-labels", "mixed" and such
        my $c = $group->result_source->schema->resultset('Comments')->search({job_id => {in => \@ids}});
        my %labels;
        while (my $comment = $c->next) {
            $labels{$comment->job_id}++;
        }
        $jobs->reset;

        while (my $job = $jobs->next) {
            $jr{distris}->{$job->DISTRI} = 1;
            my $key = $job->TEST . "-" . $job->ARCH . "-" . $job->FLAVOR . "-" . $job->MACHINE;
            next if $seen{$key}++;

            $jr{oldest} = $job->t_created if $job->t_created < $jr{oldest};
            count_job($job, \%jr, \%labels);
            if ($jr{children}) {
                my $child = $jr{children}->{$job->group_id};
                $child->{distris}->{$job->DISTRI} = 1;
                $child->{version} //= $job->VERSION;
                $child->{build}   //= $job->BUILD;
                count_job($job, $child, \%labels);
                add_review_badge($child);
            }
        }
        $jr{escaped_version} = $jr{version};
        $jr{escaped_version} =~ s/\W/_/g;
        $jr{escaped_build} = $jr{build};
        $jr{escaped_build} =~ s/\W/_/g;
        $jr{escaped_id} = join('-', $jr{escaped_version}, $jr{escaped_build});
        add_review_badge(\%jr);
        push(@sorted_results, \%jr);
        $max_jobs = $jr{total} if ($jr{total} > $max_jobs);
    }
    $result{max_jobs} = $max_jobs;
    return \%result;
}

1;

