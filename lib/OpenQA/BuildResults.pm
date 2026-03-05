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
use DateTime::Format::Pg;
use Sort::Versions;
use Time::Seconds;
use List::Util 'any';

use constant DEFAULT_MAX_JOBS_PER_BUILD => 5000;

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

sub _get_job_result_category ($state, $result) {
    if ($state eq OpenQA::Jobs::Constants::DONE) {
        my $meta = OpenQA::Jobs::Constants::meta_result($result);
        return 'passed' if $meta eq OpenQA::Jobs::Constants::PASSED;
        return 'softfailed' if $meta eq OpenQA::Jobs::Constants::SOFTFAILED;
        return 'skipped' if $meta eq OpenQA::Jobs::Constants::ABORTED;
        return 'failed' if $meta eq OpenQA::Jobs::Constants::FAILED || $meta eq OpenQA::Jobs::Constants::NOT_COMPLETE;
    }
    return 'skipped' if $state eq OpenQA::Jobs::Constants::CANCELLED;
    return 'unfinished';
}

sub _count_job_aggregated ($stat, $jr, $count) {
    $jr->{total} += $count;
    my $category = _get_job_result_category($stat->state, $stat->result);
    $jr->{$category} += $count;
}

sub count_job ($job, $jr, $labels) {

    $jr->{total}++;
    my ($state, $result) = ($job->state, $job->result);
    my $category = _get_job_result_category($state, $result);
    $jr->{$category}++;

    if ($category eq 'failed') {
        my $comment_data = $labels->{$job->id};
        if ($comment_data) {
            $jr->{labeled}++ if $comment_data->{reviewed};
            $jr->{comments}++ if $comment_data->{comments} || $comment_data->{reviewed};
        }
    }
    elsif ($category eq 'unfinished') {
        log_error('Encountered not-implemented state:' . $state . ' result:' . $result)
          unless any { $state eq $_ } (OpenQA::Jobs::Constants::PENDING_STATES);
    }
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

sub compute_build_results ($group, $limit, $time_limit_days, $tags, $subgroup_filter, $show_tags,
    $max_jobs_per_build = undef)
{

    # find relevant child groups taking filter into account
    my $child_groups = find_child_groups($group, $subgroup_filter);
    my $group_ids = $child_groups->{group_ids};
    my $children = $child_groups->{children};

    $max_jobs_per_build //= DEFAULT_MAX_JOBS_PER_BUILD;

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
    my $buildver_sort_mode
      = $group->can('build_version_sort') ? ($group->build_version_sort // BUILD_SORT_BY_NAME) : BUILD_SORT_BY_NAME;
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
    my $newest = ($buildver_sort_mode == BUILD_SORT_BY_OLDEST_JOB || $buildver_sort_mode == BUILD_SORT_BY_NAME) ? 0 : 1;
    for my $build (@builds) {
        last if defined($limit) && (--$limit < 0);

        my ($version, $buildnr) = ($build->VERSION, $build->BUILD);
        my $jobs_search_filter = {
            VERSION => $version,
            BUILD => $buildnr,
            group_id => {in => $group_ids},
            clone_id => undef,
        };
        my $latest_job_ids_rs = $jobs_resultset->search($jobs_search_filter,
            {select => [{max => 'id'}], as => [qw(id)], group_by => [qw(TEST ARCH FLAVOR MACHINE)]});
        my @latest_ids = map { $_->get_column('id') // () } $latest_job_ids_rs->all;
        next unless @latest_ids;

        my $stats_rs = $jobs_resultset->search(
            {id => {-in => \@latest_ids}},
            {
                select => [qw(state result group_id DISTRI), {count => '*'}],
                as => [qw(state result group_id DISTRI count)],
                group_by => [qw(state result group_id DISTRI)],
            });
        my %jr = (
            key => $build->{key},
            build => $buildnr,
            version => $version,
            version_count => scalar keys %{$versions_per_build{$buildnr}},
        );
        init_job_figures(\%jr);
        for my $child (@$children) {
            init_job_figures($jr{children}->{$child->id} = {version => $version});
        }
        my $total_for_build = 0;
        while (my $stat = $stats_rs->next) {
            my $count = $stat->get_column('count');
            $total_for_build += $count;
            _count_job_aggregated($stat, \%jr, $count);
            my $distri = $stat->get_column('DISTRI');
            $jr{distris}->{$distri} = 1;
            if ($jr{children}) {
                my $child = $jr{children}->{$stat->group_id};
                _count_job_aggregated($stat, $child, $count);
                $child->{distris}->{$distri} = 1;
            }
        }
        if (defined($max_jobs_per_build) && $total_for_build > $max_jobs_per_build) {
            die 'Build '
              . $buildnr . ' has '
              . $total_for_build
              . ' jobs, which exceeds the limit of '
              . $max_jobs_per_build
              . '. Please contact your openQA administrator.';
        }
        next unless $total_for_build;
        my $extra_info_rs = $jobs_resultset->search(
            {id => {-in => \@latest_ids}},
            {
                select => [{($newest ? 'max' : 'min') => 't_created'}],
                as => [qw(t_created)],
            });
        while (my $info = $extra_info_rs->next) {
            my $t_created = $info->get_column('t_created');
            if ($t_created && !ref $t_created) {
                $t_created = DateTime::Format::Pg->parse_datetime($t_created);
            }
            $jr{oldest_newest} = $newest ? ($jr{oldest_newest} // $t_created) : $t_created;
        }
        my $not_ok_rs = $jobs_resultset->search(
            {
                id => {-in => \@latest_ids},
                state => OpenQA::Jobs::Constants::DONE,
                result => {in => [OpenQA::Jobs::Constants::NOT_OK_RESULTS]},
            },
            {select => [qw(id group_id)]});
        my @not_ok_jobs = $not_ok_rs->all;
        my $comment_data = $group->result_source->schema->resultset('Comments')->comment_data_for_jobs(\@not_ok_jobs);
        for my $job (@not_ok_jobs) {
            my $cd = $comment_data->{$job->id};
            next unless $cd;
            if ($cd->{reviewed}) {
                $jr{labeled}++;
                if ($jr{children} && (my $child = $jr{children}->{$job->group_id})) {
                    $child->{labeled}++;
                }
            }
            if ($cd->{comments} || $cd->{reviewed}) {
                $jr{comments}++;
                if ($jr{children} && (my $child = $jr{children}->{$job->group_id})) {
                    $child->{comments}++;
                }
            }
        }
        if ($jr{children}) {
            for my $child_id (keys %{$jr{children}}) {
                add_review_badge($jr{children}->{$child_id});
            }
        }

        $jr{date} = delete $jr{oldest_newest};
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
