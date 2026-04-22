# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::BuildResults;

use Mojo::Base -strict, -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Constants qw(BUILD_SORT_BY_NAME BUILD_SORT_BY_NEWEST_JOB BUILD_SORT_BY_OLDEST_JOB);
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils;
use Date::Format;
use DateTime::Format::Pg;
use List::Util qw(any);
use Sort::Versions;
use Time::Seconds;

use constant DEFAULT_BUILD_RESULTS_LIMIT => 400;

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

sub add_review_badge ($build_res) {
    $build_res->{all_passed} = $build_res->{passed} + $build_res->{softfailed} >= $build_res->{total} ? 1 : 0;
    $build_res->{reviewed} = $build_res->{labeled} >= $build_res->{failed} ? 1 : 0;
    $build_res->{commented} = $build_res->{comments} >= $build_res->{failed} ? 1 : 0;
}

sub find_child_groups ($group, $subgroup_filter) {
    return {
        group_ids => [$group->id],
        children => [],
    } unless $group->can('children');

    my @children = grep { !$_->ignore_on_dashboard } $group->children;
    if (@$subgroup_filter) {
        @children = grep {
            my $full_name = $_->full_name;
            grep { $_ eq '' || regex_match($_, $full_name) } @$subgroup_filter
        } @children;
    }
    return {
        group_ids => [map { $_->id } @children],
        children => \@children,
    };
}

sub _get_latest_job_ids ($jobs_resultset, $version, $buildnr, $group_ids) {
    return map { $_->id } $jobs_resultset->search(
        {VERSION => $version, BUILD => $buildnr, group_id => {in => $group_ids}, clone_id => undef},
        {select => [{max => 'id'}], as => ['id'], group_by => [qw(TEST ARCH FLAVOR MACHINE)]})->all;
}

sub compute_build_results (
    $group, $limit, $time_limit_days, $tags, $subgroup_filter, $show_tags,
    $max_jobs_limit = undef,
    $ignored_groups = undef
  )
{
    # find relevant child groups taking filter into account
    my $child_groups = find_child_groups($group, $subgroup_filter);
    my $group_ids = $child_groups->{group_ids};
    my $children = $child_groups->{children};

    if ($ignored_groups) {
        if (@$children) {
            $children = [grep { !$ignored_groups->{$_->name} } @$children];
            $group_ids = [map { $_->id } @$children];
        }
        else {
            $group_ids = [grep { !$ignored_groups->{$group->name} } @$group_ids];
        }
    }

    my $total_jobs_seen = 0;
    my $limit_exceeded = 0;
    my @sorted_results;
    my %result = (
        build_results => \@sorted_results,
        max_jobs => 0,
        limit_exceeded => 0,
        children => [map { {id => $_->id, name => $_->name} } @$children],
        group => {
            id => $group->id,
            name => $group->name
        });
    return \%result if defined($limit) && int($limit) <= 0;
    # build sorting
    my $buildver_sort_mode = BUILD_SORT_BY_NAME;
    $buildver_sort_mode = $group->build_version_sort if $group->can('build_version_sort');
    my $sort_column = $buildver_sort_mode == BUILD_SORT_BY_OLDEST_JOB ? 'oldest_job' : 'newest_job';

    # 400 is the max. limit selectable in the group overview
    my $row_limit = (defined($limit) && $limit > DEFAULT_BUILD_RESULTS_LIMIT) ? $limit : DEFAULT_BUILD_RESULTS_LIMIT;
    my @search_cols = qw(VERSION BUILD);
    my %search_opts = (
        select => [@search_cols, {max => 'id', -as => 'newest_job'}, {min => 'id', -as => 'oldest_job'}],
        group_by => \@search_cols,
        order_by => {-desc => $sort_column},
        rows => $row_limit
    );
    my %search_filter = (group_id => {in => $group_ids});
    $search_filter{t_created} = {'>' => time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * $time_limit_days, 'UTC')}
      if $time_limit_days;
    # add search filter for tags
    # caveat: a tag that references only a build, not including a version, might be ambiguous
    if ($tags) {
        my @builds;
        my @versions;
        for my $tag_id (keys %$tags) {
            my $tag = $tags->{$tag_id};
            push @builds, $tag->{build} if $tag->{build};
            push @versions, $tag->{version} if $tag->{version};
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
        $build->{key} = join '-', $version, $buildnr;
        $versions_per_build{$buildnr}->{$version} = 1;
    }
    @builds = reverse sort { versioncmp($a->{key}, $b->{key}); } @builds
      if $buildver_sort_mode == BUILD_SORT_BY_NAME;
    my $max_jobs = 0;
    my $newest = ($buildver_sort_mode == BUILD_SORT_BY_OLDEST_JOB || $buildver_sort_mode == BUILD_SORT_BY_NAME) ? 0 : 1;
    for my $build (@builds) {
        if (defined $max_jobs_limit && $total_jobs_seen >= $max_jobs_limit) {
            $limit_exceeded = 1;
            last;
        }
        last if defined $limit && (--$limit < 0);
        my ($version, $buildnr) = ($build->VERSION, $build->BUILD);
        my @latest_ids = _get_latest_job_ids($jobs_resultset, $version, $buildnr, $group_ids);
        if (defined $max_jobs_limit && $total_jobs_seen + scalar(@latest_ids) > $max_jobs_limit) {
            $limit_exceeded = 1;
            splice @latest_ids, $max_jobs_limit - $total_jobs_seen;
        }
        next unless @latest_ids;
        my %jr = (
            key => $build->{key},
            build => $buildnr,
            version => $version,
            version_count => scalar keys %{$versions_per_build{$buildnr}},
        );
        init_job_figures(\%jr);
        init_job_figures($jr{children}->{$_->id} = {}) for @$children;
        my $stats_rs = $jobs_resultset->search(
            {id => {-in => \@latest_ids}},
            {
                select =>
                  [qw(state result DISTRI group_id), {count => '*'}, {($newest ? 'max' : 'min') => 't_created'}],
                as => [qw(state result DISTRI group_id count t_created_agg)],
                group_by => [qw(state result DISTRI group_id)],
            });
        while (my $stat = $stats_rs->next) {
            my $count = $stat->get_column('count');
            $jr{total} += $count;
            $jr{distris}->{$stat->DISTRI} = 1;
            my $t_agg = $stat->get_column('t_created_agg');
            if ($t_agg && !ref $t_agg) {
                $t_agg = DateTime::Format::Pg->parse_datetime($t_agg);
            }
            if ($newest) {
                $jr{oldest_newest} = $t_agg if !$jr{oldest_newest} || $t_agg > $jr{oldest_newest};
            }
            else {
                $jr{oldest_newest} = $t_agg if !$jr{oldest_newest} || $t_agg < $jr{oldest_newest};
            }
            my $cat = 'unfinished';
            if ($stat->state eq OpenQA::Jobs::Constants::DONE) {
                if ($stat->result eq OpenQA::Jobs::Constants::PASSED) { $cat = 'passed' }
                elsif ($stat->result eq OpenQA::Jobs::Constants::SOFTFAILED) { $cat = 'softfailed' }
                elsif (any { $stat->result eq $_ } OpenQA::Jobs::Constants::ABORTED_RESULTS) {
                    $cat = 'skipped';
                }
                elsif (any { $stat->result eq $_ } OpenQA::Jobs::Constants::NOT_OK_RESULTS) {
                    $cat = 'failed';
                }
            }
            elsif ($stat->state eq OpenQA::Jobs::Constants::CANCELLED) { $cat = 'skipped' }
            $jr{$cat} += $count;
            if ($jr{children} && (my $child = $jr{children}->{$stat->group_id})) {
                $child->{total} += $count;
                $child->{$cat} += $count;
                $child->{distris}->{$stat->DISTRI} = 1;
                $child->{version} //= $version;
                $child->{build} //= $buildnr;
            }
        }
        my $failed_rs = $jobs_resultset->search(
            {
                id => {-in => \@latest_ids},
                state => OpenQA::Jobs::Constants::DONE,
                result => {in => [OpenQA::Jobs::Constants::FAILED, OpenQA::Jobs::Constants::NOT_COMPLETE_RESULTS]},
            },
            {select => [qw(id group_id)]});
        my $failed_id_to_group = {map { $_->id => $_->group_id } $failed_rs->all};
        if (keys %$failed_id_to_group) {
            my $comment_data = $group->result_source->schema->resultset('Comments')->comment_data_for_jobs($failed_rs);
            for my $id (keys %$comment_data) {
                my $cd = $comment_data->{$id};
                next unless $cd->{reviewed} || $cd->{comments};
                $jr{labeled}++ if $cd->{reviewed};
                $jr{comments}++ if $cd->{comments} || $cd->{reviewed};
                if ($jr{children} && (my $child = $jr{children}->{$failed_id_to_group->{$id}})) {
                    $child->{labeled}++ if $cd->{reviewed};
                    $child->{comments}++ if $cd->{comments} || $cd->{reviewed};
                }
            }
        }
        add_review_badge($_) for values %{$jr{children} // {}};
        $total_jobs_seen += $jr{total};
        $jr{date} = delete $jr{oldest_newest};
        $jr{escaped_version} = $jr{version};
        $jr{escaped_version} =~ s/\W/_/g;
        $jr{escaped_build} = $jr{build};
        $jr{escaped_build} =~ s/\W/_/g;
        $jr{escaped_id} = join '-', $jr{escaped_version}, $jr{escaped_build};
        add_review_badge(\%jr);
        push @sorted_results, \%jr;
        $max_jobs = $jr{total} if ($jr{total} > $max_jobs);
    }
    $result{max_jobs} = $max_jobs;
    $result{total_jobs} = $total_jobs_seen;
    $result{limit_exceeded} = $limit_exceeded ? 1 : 0;
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
