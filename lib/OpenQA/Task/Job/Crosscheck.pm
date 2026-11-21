# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::Crosscheck;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_debug log_info log_warning);
use OpenQA::Utils qw(prjdir);
use OpenQA::Task::SignalGuard;
use List::Util 'min';
use Time::Seconds;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File;
use Feature::Compat::Try;

use constant DEFAULT_GROUPS_PER_BATCH => 20;
use constant MAX_SAMPLES => 20;
use constant MIN_DIR_AGE => ONE_DAY;
use constant TASK_NAME => 'crosscheck_results_consistency';
use constant TASK_PRIORITY => -100;
use constant TASK_TTL => 7 * ONE_DAY;
use constant GUARD_NAME => 'crosscheck_results_task';
use constant CLEANUP_TASK => 'limit_results_and_logs';

sub register ($self, $app, @args) {
    $app->minion->add_task(TASK_NAME, \&_crosscheck);
}

my %PHASES = (parent => \&_parent, groups => \&_groups, summary => \&_summary);

sub _crosscheck ($job, $args = undef) {
    return $job->fail({error => 'The specified crosscheck phase is invalid.'})
      unless my $phase = $PHASES{$args->{phase} // 'parent'};
    return $phase->($job, $args);
}

sub _cursor_path () { prjdir() . '/webui/cache/crosscheck-status.json' }

sub _read_cursor () {
    my $path = _cursor_path();
    return {} unless -f $path;
    try {
        return decode_json(Mojo::File->new($path)->slurp);
    }
    catch ($e) {
        log_warning("Unable to read crosscheck status from $path: $e");
        return {};
    }
}

sub _write_cursor ($group_id) {
    my $path = _cursor_path();
    try {
        my $cache_file = Mojo::File->new("$path.new");
        $cache_file->dirname->make_path();
        $cache_file->spew(encode_json({last_group_id => $group_id}))->move_to($path);
        log_debug("Saved crosscheck status: last processed group ID is $group_id");
    }
    catch ($e) {
        log_warning("Unable to write crosscheck status to $path: $e");
    }
}

sub _is_stale ($dir) { Mojo::File->new($dir)->stat->mtime < time - MIN_DIR_AGE }

sub _add_sample ($samples, $path) { push @$samples, $path if @$samples < MAX_SAMPLES }

# jobs whose results are recorded as cleaned must not have a directory anymore
sub _count_cleaned_with_dir ($group, $counts, $samples) {
    return undef unless my $jobs = $group->find_jobs_with_cleaned_results;
    for my $openqa_job ($jobs->all) {
        $counts->{checked_jobs} += 1;
        my $dir = $openqa_job->result_dir;
        next unless $dir && -d $dir && _is_stale($dir);
        $counts->{cleaned_with_dir} += 1;
        log_debug('job ' . $openqa_job->id . ' is recorded as cleaned, but ' . $dir . ' still exists');
        _add_sample($samples, $dir);
    }
}

# jobs whose results are recorded as present must have a directory
sub _count_results_without_dir ($group, $counts, $samples) {
    return undef unless my $jobs = $group->find_jobs_with_present_results;
    for my $openqa_job ($jobs->all) {
        $counts->{checked_jobs} += 1;
        my $dir = $openqa_job->result_dir;
        next if $dir && -d $dir;
        $counts->{results_without_dir} += 1;
        log_debug('job ' . $openqa_job->id . ' has results recorded, but ' . ($dir // 'no result_dir') . ' is gone');
        _add_sample($samples, $dir // ('job ' . $openqa_job->id));
    }
}

sub _groups ($job, $args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    return $job->retry({delay => ONE_MINUTE})
      unless my $crosscheck_guard = $job->app->minion->guard(GUARD_NAME, ONE_DAY);

    my $group_ids = $args->{group_ids};
    my $groups = $job->app->schema->resultset('JobGroups');
    my %counts = (checked_jobs => 0, cleaned_with_dir => 0, results_without_dir => 0, groups_checked => 0);
    my @samples;
    for my $group_id (@$group_ids) {
        # a group can be deleted between the parent job and the batch
        next unless my $group = $groups->find($group_id);
        $counts{groups_checked} += 1;
        _count_cleaned_with_dir($group, \%counts, \@samples);
        _count_results_without_dir($group, \%counts, \@samples);
    }

    $counts{samples} = \@samples;
    $job->note(crosscheck => \%counts);
    _write_cursor($group_ids->[-1]);
    $ensure_task_retry_on_termination_signal_guard->retry(0);
    return $job->finish(\%counts);
}

sub _summary ($job, $args) {
    my $minion = $job->app->minion;
    my %summary = (checked_jobs => 0, cleaned_with_dir => 0, results_without_dir => 0, groups_checked => 0);
    my @samples;
    for my $child_id (@{$args->{child_ids}}) {
        # a child can be removed by its ttl before the summary runs
        next unless my $child = $minion->job($child_id);
        my $counts = $child->info->{notes}{crosscheck} // {};
        $summary{$_} += $counts->{$_} // 0 for qw(checked_jobs cleaned_with_dir results_without_dir groups_checked);
        for my $sample (@{$counts->{samples} // []}) {
            last if @samples >= MAX_SAMPLES;
            push @samples, $sample;
        }
    }
    $summary{samples} = \@samples;
    $job->note(crosscheck_summary => \%summary);
    $minion->job($args->{parent_job_id})->note(crosscheck_summary => \%summary) if $args->{parent_job_id};
    log_info('Crosscheck summary: ' . join ' ',
        @summary{qw(checked_jobs cleaned_with_dir results_without_dir groups_checked)});
    return $job->finish(
        {
            checked_jobs => $summary{checked_jobs},
            cleaned_with_dir => $summary{cleaned_with_dir},
            results_without_dir => $summary{results_without_dir}});
}

sub _parent ($job, $args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $app = $job->app;
    return $job->retry({delay => ONE_MINUTE})
      unless my $crosscheck_guard = $app->minion->guard(GUARD_NAME, ONE_DAY);

    # the daily cleanup is the heavier job on the same disks, so it gets the slots and the crosscheck stays idle
    my $cleanup_jobs = $app->minion->jobs({tasks => [CLEANUP_TASK], states => [qw(inactive active)]})->total;
    return $job->finish("Skipping, there are still $cleanup_jobs inactive/active cleanup jobs") if $cleanup_jobs;

    my $groups_rs = $app->schema->resultset('JobGroups')->search(undef, {order_by => 'id', columns => 'id'});
    my @groups = map { $_->id } $groups_rs->all;
    return $job->finish('Done, no job groups present') unless @groups;

    # round-robin over the groups like the daily cleanup does, so a monthly run resumes where the last stopped
    my $last_group_id = _read_cursor->{last_group_id};
    if (defined $last_group_id) {
        my @greater_than = grep { $_ > $last_group_id } @groups;
        my @less_or_equal = grep { $_ <= $last_group_id } @groups;
        @groups = (@greater_than, @less_or_equal);
    }

    my $groups_per_batch = $args->{groups_per_batch} // $app->config->{misc_limits}->{crosscheck_groups_per_batch}
      // DEFAULT_GROUPS_PER_BATCH;
    my $gru = $app->gru;
    # lowest priority: the daily cleanup runs with 5, archive and screenshot children with -20, and the
    # Minion backend dequeues the highest priority first
    my %options = (priority => TASK_PRIORITY, ttl => TASK_TTL);
    my @child_ids;
    my @batches;
    for (my $i = 0; $i < @groups; $i += $groups_per_batch) {
        my @batch = @groups[$i .. min($#groups, $i + $groups_per_batch - 1)];
        my $child = $gru->enqueue(TASK_NAME, {phase => 'groups', group_ids => \@batch}, \%options);
        push @child_ids, $child->{minion_id};
        push @batches, {min_group_id => $batch[0], max_group_id => $batch[-1]};
    }

    # the summary can only aggregate once every batch noted its counts
    my $summary = $gru->enqueue(
        TASK_NAME,
        {phase => 'summary', parent_job_id => $job->id, child_ids => \@child_ids},
        {priority => TASK_PRIORITY, ttl => TASK_TTL, parents => \@child_ids});

    $job->note(crosscheck => {groups_checked => scalar @groups, batches => scalar @batches});
    $ensure_task_retry_on_termination_signal_guard->retry(0);
    return $job->finish(
        {groups_checked => scalar @groups, batches => scalar @batches, summary_job_id => $summary->{minion_id}});
}

1;

=encoding utf8

=head1 NAME

OpenQA::Task::Job::Crosscheck - Crosscheck the results in the database against the filesystem

=head1 SYNOPSIS

    $app->plugin('OpenQA::Task::Job::Crosscheck');

=head1 DESCRIPTION

L<OpenQA::Task::Job::Crosscheck> registers the C<crosscheck_results_consistency> Minion task. Its parent job
chunks the job groups into batches, each batch reports jobs whose results are recorded as cleaned but that
still have a directory, and jobs whose results are recorded as present but that have no directory. A summary
job aggregates the counts of all batches into the note of the parent job. It is a read-only integrity check:
nothing is deleted or repaired.

=cut
