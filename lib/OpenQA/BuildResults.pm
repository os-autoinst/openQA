# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::BuildResults;

use Mojo::Base -strict, -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Constants qw(BUILD_SORT_BY_NAME BUILD_SORT_BY_NEWEST_JOB BUILD_SORT_BY_OLDEST_JOB);
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils;
use OpenQA::Log qw(log_error);
use Date::Format;
use Sort::Versions;
use Time::Seconds;

sub init_job_figures ($job_result) {

    # relevant distributions for the build (hash is used as a set)
    $job_result->{distris} = {};

    # number of passed/failed/... jobs
    $job_result->{passed} = 0;
    $job_result->{failed} = 0;
    $job_result->{unfinished} = 0;
    $job_result->{labeled} = 0;
    $job_result->{comments} = 0;
    $job_result->{softfailed} = 0;
    $job_result->{skipped} = 0;
    $job_result->{total} = 0;
}

sub count_job ($job, $jr, $labels) {

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
            my $comment_data = $labels->{$job->id};
            $jr->{failed}++;
            if ($comment_data) {
                $jr->{labeled}++ if $comment_data->{reviewed};
                $jr->{comments}++ if $comment_data->{comments} || $comment_data->{reviewed};
            }
            return;
        }
        # note: Incompletes and timeouts are accounted to both categories - failed and skipped.
    }
    if ($job->state eq OpenQA::Jobs::Constants::CANCELLED) {
        $jr->{skipped}++;
        return;
    }
    my $state = $job->state;
    log_error('Encountered not-implemented state:' . $job->state . ' result:' . $job->result)
      unless grep { /$state/ } (OpenQA::Jobs::Constants::PENDING_STATES);
    $jr->{unfinished}++;
    return;
}

sub add_review_badge ($build_res) {

    $build_res->{all_passed} = $build_res->{passed} + $build_res->{softfailed} >= $build_res->{total} ? 1 : 0;
    $build_res->{reviewed} = $build_res->{labeled} >= $build_res->{failed} ? 1 : 0;
    $build_res->{commented} = $build_res->{comments} >= $build_res->{failed} ? 1 : 0;
}

sub filter_subgroups ($group, $subgroup_filter) {

    my @group_ids;
    my @children;
    my $group_name = $group->name;

    for my $child ($group->children) {
        my $full_name = $child->full_name;
        if (grep { $_ eq '' || regex_match($_, $full_name) } @$subgroup_filter) {
            push(@group_ids, $child->id);
            push(@children, $child);
        }
    }
    return {
        group_ids => \@group_ids,
        children => \@children,
    };
}

sub find_child_groups ($group, $subgroup_filter) {

    # handle regular (non-parent) groups
    return {
        group_ids => [$group->id],
        children => [],
    } unless $group->can('children');

    # handle simple case where no filter for subgroups present
    return {
        group_ids => $group->child_group_ids,
        children => [$group->children],
    } unless @$subgroup_filter;

    return filter_subgroups($group, $subgroup_filter);
}

sub compute_build_results ($group, $limit, $time_limit_days, $tags, $subgroup_filter, $show_tags) {

    # find relevant child groups taking filter into account
    my $child_groups = find_child_groups($group, $subgroup_filter);
    my $group_ids = $child_groups->{group_ids};
    my $children = $child_groups->{children};

    my @sorted_results;
    my %result = (
        build_results => \@sorted_results,
        max_jobs => 0,
        children => [map { {id => $_->id, name => $_->name} } @$children],
        group => {
            id => $group->id,
            name => $group->name
        });

    if (defined($limit) && int($limit) <= 0) {
        return \%result;
    }

    # build sorting
    my $buildver_sort_mode = BUILD_SORT_BY_NAME;
    $buildver_sort_mode = $group->build_version_sort if $group->can('build_version_sort');
    my $sort_column = $buildver_sort_mode == BUILD_SORT_BY_OLDEST_JOB ? 'oldest_job' : 'newest_job';

    # 400 is the max. limit selectable in the group overview
    my $row_limit = (defined($limit) && $limit > 400) ? $limit : 400;
    my @search_cols = qw(VERSION BUILD);
    my %search_opts = (
        select => [@search_cols, {max => 'id', -as => 'newest_job'}, {min => 'id', -as => 'oldest_job'}],
        group_by => \@search_cols,
        order_by => {-desc => $sort_column},
        rows => $row_limit
    );
    my %search_filter = (group_id => {in => $group_ids});
    if ($time_limit_days) {
        $search_filter{t_created}
          = {'>' => time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * $time_limit_days, 'UTC')};
    }

    # add search filter for tags
    # caveat: a tag that references only a build, not including a version, might be ambiguous
    if ($tags) {
        my @builds;
        my @versions;
        for my $tag_id (keys %$tags) {
            my $tag = $tags->{$tag_id};
            push(@builds, $tag->{build}) if $tag->{build};
            push(@versions, $tag->{version}) if $tag->{version};
        }
        $search_filter{BUILD} = {-in => \@builds};
        $search_filter{VERSION} = {-in => \@versions} if @versions;
    }

    # find relevant builds
    my $jobs_resultset = $group->result_source->schema->resultset('Jobs');
    my @builds = $jobs_resultset->search(\%search_filter, \%search_opts)->all;
    my %versions_per_build;
    for my $build (@builds) {
        my ($version, $buildnr) = ($build->VERSION, $build->BUILD);
        $build->{key} = join('-', $version, $buildnr);
        $versions_per_build{$buildnr}->{$version} = 1;
    }
    if ($buildver_sort_mode == BUILD_SORT_BY_NAME) {
        @builds = reverse sort { versioncmp($a->{key}, $b->{key}); } @builds;
    }

    my $max_jobs = 0;
    my $now = DateTime->now;
    for my $build (@builds) {
        last if defined($limit) && (--$limit < 0);

        my ($version, $buildnr) = ($build->VERSION, $build->BUILD);
        my $jobs = $jobs_resultset->search(
            {
                VERSION => $version,
                BUILD => $buildnr,
                group_id => {in => $group_ids},
                clone_id => undef,
            },
            {order_by => 'me.id DESC'});
        my $date_ref_job_col
          = ($buildver_sort_mode == BUILD_SORT_BY_OLDEST_JOB || $buildver_sort_mode == BUILD_SORT_BY_NAME)
          ? 'oldest_job'
          : 'newest_job';
        my $date_ref_job = $build->{_column_data}->{$date_ref_job_col};
        my %jr = (
            key => $build->{key},
            build => $buildnr,
            version => $version,
            version_count => scalar keys %{$versions_per_build{$buildnr}},
            date_mode => $date_ref_job_col,
        );
        init_job_figures(\%jr);
        for my $child (@$children) {
            init_job_figures($jr{children}->{$child->id} = {});
        }

        my %seen;
        my @jobs = map {
            my $key = $_->TEST . '-' . $_->ARCH . '-' . $_->FLAVOR . '-' . ($_->MACHINE // '');
            $seen{$key}++ ? () : $_;
        } $jobs->all;
        my $comment_data = $group->result_source->schema->resultset('Comments')->comment_data_for_jobs(\@jobs);
        for my $job (@jobs) {
            $jr{distris}->{$job->DISTRI} = 1;
            $jr{date} = $job->t_created if $job->id == $date_ref_job;
            count_job($job, \%jr, $comment_data);
            if ($jr{children}) {
                my $child = $jr{children}->{$job->group_id};
                $child->{distris}->{$job->DISTRI} = 1;
                $child->{version} //= $job->VERSION;
                $child->{build} //= $job->BUILD;
                count_job($job, $child, $comment_data);
                add_review_badge($child);
            }
        }
        unless (defined $jr{date}) {
            # job was not in @jobs - so fetch it from db
            my $job = $jobs_resultset->find($date_ref_job);
            $jr{date} = (defined $job) ? $job->t_created : DateTime->from_epoch(0);
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
    _map_tags_into_build($result{build_results}, $show_tags) if $show_tags;
    return \%result;
}

sub _map_tags_into_build ($results, $tags) {
    for my $res (@$results) {
        if (my $full_tag = $tags->{$res->{key}}) {
            $res->{tag} = $full_tag;
        }
        elsif (my $build_only_tag = $tags->{$res->{build}}) {
            # as fallback we are looking for build and not other criteria we can end
            # up with multiple tags if the build appears more than once, e.g.
            # for each version
            $res->{tag} = $build_only_tag;
        }
    }
}


1;
