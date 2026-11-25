# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::Crosscheck;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_debug log_info log_warning);
use OpenQA::Utils qw(prjdir resultdir);
use OpenQA::Task::SignalGuard;
use List::Util 'min';
use Time::Seconds;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File;
use Feature::Compat::Try;

use constant DEFAULT_GROUPS_PER_BATCH => 20;
use constant DEFAULT_PREFIXES_PER_BATCH => 20;
use constant DEFAULT_INTERVAL_DAYS => 30;
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

# the timer ticks daily, so the interval comes from the config and a finished run within it suppresses the enqueue
sub enqueue_if_due ($app) {
    return undef unless $app->config->{cleanup}->{crosscheck};
    my $interval_days = $app->config->{cleanup}->{crosscheck_interval_days} // DEFAULT_INTERVAL_DAYS;
    if ($interval_days > 0) {
        my $last = $app->minion->backend->list_jobs(0, 1, {tasks => [TASK_NAME], states => ['finished']})->{jobs}->[0];
        return undef if $last && ($last->{finished} // 0) > time - $interval_days * ONE_DAY;
    }
    return $app->gru->enqueue(TASK_NAME, [], {priority => TASK_PRIORITY, ttl => TASK_TTL, limit => 1})->{minion_id};
}

my %PHASES = (parent => \&_parent, groups => \&_groups, prefixes => \&_prefixes, summary => \&_summary);

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

sub _write_cursor ($key, $value) {
    my $path = _cursor_path();
    try {
        my $cache_file = Mojo::File->new("$path.new");
        $cache_file->dirname->make_path();
        $cache_file->spew(encode_json({%{_read_cursor()}, $key => $value}))->move_to($path);
        log_debug("Saved crosscheck status: $key is $value");
    }
    catch ($e) {
        log_warning("Unable to write crosscheck status to $path: $e");
    }
}

sub _is_stale ($dir) { Mojo::File->new($dir)->stat->mtime < time - MIN_DIR_AGE }

sub _add_sample ($samples, $path) { push @$samples, $path if @$samples < MAX_SAMPLES }

# repair is limited to directories the crosscheck reported as leftover, and only a directory that is still there
# right now is removed, so a concurrent cleanup or a newer upload cannot be hit
sub _remove_leftover ($repair, $counts, $dir, $what) {
    return undef unless $repair && -d $dir && _is_stale($dir);
    try {
        Mojo::File->new($dir)->remove_tree;
    }
    catch ($e) {
        log_warning("Unable to remove leftover $dir: $e");
        return undef;
    }
    $counts->{repaired} += 1;
    log_info("Removed $what at $dir");
    return 1;
}

# jobs whose results are recorded as cleaned must not have a directory anymore
sub _count_cleaned_with_dir ($group, $counts, $samples, $repair) {
    return undef unless my $jobs = $group->find_jobs_with_cleaned_results;
    for my $openqa_job ($jobs->all) {
        $counts->{checked_jobs} += 1;
        my $dir = $openqa_job->result_dir;
        next unless $dir && -d $dir && _is_stale($dir);
        $counts->{cleaned_with_dir} += 1;
        log_debug('job ' . $openqa_job->id . ' is recorded as cleaned, but ' . $dir . ' still exists');
        _add_sample($samples, $dir);
        _remove_leftover($repair, $counts, $dir, 'the results directory of cleaned job ' . $openqa_job->id);
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
    my $repair = $args->{repair};
    $counts{repaired} = 0 if $repair;
    my @samples;
    for my $group_id (@$group_ids) {
        # a group can be deleted between the parent job and the batch
        next unless my $group = $groups->find($group_id);
        $counts{groups_checked} += 1;
        _count_cleaned_with_dir($group, \%counts, \@samples, $repair);
        _count_results_without_dir($group, \%counts, \@samples);
    }

    $counts{samples} = \@samples;
    $job->note(crosscheck => \%counts);
    _write_cursor(last_group_id => $group_ids->[-1]);
    $ensure_task_retry_on_termination_signal_guard->retry(0);
    return $job->finish(\%counts);
}

sub _prefixes ($job, $args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    return $job->retry({delay => ONE_MINUTE})
      unless my $crosscheck_guard = $job->app->minion->guard(GUARD_NAME, ONE_DAY);

    my %counts = (
        entries_scanned => 0,
        prefixes_checked => 0,
        orphan_dirs => 0,
        cleaned_with_dir => 0,
        archived_with_dir => 0,
        archived_copy => 0
    );
    my $repair = $args->{repair};
    $counts{repaired} = 0 if $repair;
    my @samples;
    for my $batch (@{$args->{prefixes}}) {
        my $prefix_dir = Mojo::File->new($batch->{base}, $batch->{prefix});
        next unless -d $prefix_dir;
        $counts{prefixes_checked} += 1;
        my $prefix = $batch->{prefix};
        my @entries = grep { -d && $_->basename =~ /^\d+/ } @{$prefix_dir->list({dir => 1})};
        $counts{entries_scanned} += @entries;
        my %rows = map { $_->id => $_ } $job->app->schema->resultset('Jobs')->search(
            {id => {-between => [$prefix * 1000, $prefix * 1000 + 999]}},
            {columns => [qw(id result_size archived state)], order_by => 'id'})->all;
        for my $entry (@entries) {
            # a directory that is not a day old is an upload in progress, not a mismatch
            next if $entry->stat->mtime > time - MIN_DIR_AGE;
            my ($zero_padded_id) = $entry->basename =~ /^(\d+)/;
            my $id = 0 + $zero_padded_id;
            my $row = $rows{$id};
            next if $row && !grep { $row->state eq $_ } FINAL_STATES;
            my ($counter, $why);
            my $in_archive = $batch->{base} eq resultdir(1);
            if (!$row) {
                ($counter, $why) = (orphan_dirs => ' has no job row');
            }
            elsif (defined $row->result_size && !$row->result_size) {
                ($counter, $why) = (cleaned_with_dir => ' is recorded as cleaned, but the directory still exists');
            }
            elsif ($row->archived && !$in_archive) {
                ($counter, $why) = (archived_with_dir => ' is archived, but the directory is in the results tree');
            }
            elsif (!$row->archived && $in_archive) {
                ($counter, $why) = (archived_copy => ' has results in the results tree, but the directory is archived');
            }
            else {
                next;
            }
            $counts{$counter} += 1;
            log_debug('job ' . $id . $why);
            _add_sample(\@samples, "$entry");
            # the wrong tree and the missing directory are manual decisions, only leftovers are safe to remove
            _remove_leftover($repair, \%counts, "$entry", 'results directory without a job row')
              if $counter eq 'orphan_dirs';
            _remove_leftover($repair, \%counts, "$entry", "results directory of cleaned job $id")
              if $counter eq 'cleaned_with_dir';
        }
    }

    $counts{samples} = \@samples;
    $job->note(crosscheck => \%counts);
    my $last = $args->{prefixes}[-1];
    _write_cursor(last_prefix => "$last->{base}/$last->{prefix}");
    $ensure_task_retry_on_termination_signal_guard->retry(0);
    return $job->finish(\%counts);
}

sub _summary ($job, $args) {
    my $minion = $job->app->minion;
    my %summary;
    my @samples;
    for my $child_id (@{$args->{child_ids}}) {
        # a child can be removed by its ttl before the summary runs
        next unless my $child = $minion->job($child_id);
        my $counts = $child->info->{notes}{crosscheck} // {};
        for my $key (keys %$counts) {
            next if $key eq 'samples';
            $summary{$key} += $counts->{$key} // 0;
        }
        for my $sample (@{$counts->{samples} // []}) {
            # the same directory is reported by the group batch of its job and by the batch of its prefix
            next if grep { $_ eq $sample } @samples;
            last if @samples >= MAX_SAMPLES;
            push @samples, $sample;
        }
    }
    $summary{samples} = \@samples;
    $job->note(crosscheck_summary => \%summary);
    $minion->job($args->{parent_job_id})->note(crosscheck_summary => \%summary) if $args->{parent_job_id};
    log_info('Crosscheck summary: ' . join ' ', map { "$_=$summary{$_}" } grep { $_ ne 'samples' } sort keys %summary);
    return $job->finish(\%summary);
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

    # the prefix directories of the results and archives are named after the thousand block of the job ID
    my %prefixes;
    for my $base (resultdir(), resultdir(1)) {
        $prefixes{"$base/" . $_->basename} = {base => $base, prefix => $_->basename}
          for grep { -d && $_->basename =~ /^\d{5}$/ } @{Mojo::File->new($base)->list({dir => 1})};
    }
    my @prefix_keys = sort keys %prefixes;
    return $job->finish('Done, no job groups and no results present') unless @groups || @prefix_keys;

    # round-robin over the groups and prefixes like the daily cleanup does, so a monthly run resumes where the last
    # run stopped
    my $cursor = _read_cursor();
    my $last_group_id = $cursor->{last_group_id};
    if (defined $last_group_id) {
        my @greater_than = grep { $_ > $last_group_id } @groups;
        my @less_or_equal = grep { $_ <= $last_group_id } @groups;
        @groups = (@greater_than, @less_or_equal);
    }
    my $last_prefix = $cursor->{last_prefix};
    if (defined $last_prefix) {
        my @greater_than = grep { $_ gt $last_prefix } @prefix_keys;
        my @less_or_equal = grep { $_ le $last_prefix } @prefix_keys;
        @prefix_keys = (@greater_than, @less_or_equal);
    }

    my $groups_per_batch = $args->{groups_per_batch} // $app->config->{misc_limits}->{crosscheck_groups_per_batch}
      // DEFAULT_GROUPS_PER_BATCH;
    my $prefixes_per_batch = $args->{prefixes_per_batch}
      // $app->config->{misc_limits}->{crosscheck_prefixes_per_batch} // DEFAULT_PREFIXES_PER_BATCH;
    my $gru = $app->gru;
    # lowest priority: the daily cleanup runs with 5, archive and screenshot children with -20, and the
    # Minion backend dequeues the highest priority first
    my %options = (priority => TASK_PRIORITY, ttl => TASK_TTL);
    # repair is never implied: without the explicit argument the run only reports
    my $repair = $args->{repair} ? 1 : 0;
    log_info('Crosscheck runs in repair mode, leftover directories will be removed') if $repair;
    my @child_ids;
    my @batches;
    my @prefix_batches;
    for (my $i = 0; $i < @groups; $i += $groups_per_batch) {
        my @batch = @groups[$i .. min($#groups, $i + $groups_per_batch - 1)];
        my $child = $gru->enqueue(TASK_NAME, {phase => 'groups', group_ids => \@batch, repair => $repair}, \%options);
        push @child_ids, $child->{minion_id};
        push @batches, {min_group_id => $batch[0], max_group_id => $batch[-1]};
    }
    for (my $i = 0; $i < @prefix_keys; $i += $prefixes_per_batch) {
        my @batch = @prefix_keys[$i .. min($#prefix_keys, $i + $prefixes_per_batch - 1)];
        my $child = $gru->enqueue(
            TASK_NAME,
            {
                phase => 'prefixes',
                prefixes => [map { $prefixes{$_} } @batch],
                repair => $repair
            },
            \%options
        );
        push @child_ids, $child->{minion_id};
        push @prefix_batches, {min_prefix => $batch[0], max_prefix => $batch[-1]};
    }

    # the summary can only aggregate once every batch noted its counts
    my $summary = $gru->enqueue(
        TASK_NAME,
        {phase => 'summary', parent_job_id => $job->id, child_ids => \@child_ids},
        {priority => TASK_PRIORITY, ttl => TASK_TTL, parents => \@child_ids});

    $job->note(
        crosscheck => {
            groups_checked => scalar @groups,
            batches => scalar @batches,
            prefixes_checked => scalar @prefix_keys,
            prefix_batches => scalar @prefix_batches
        });
    $ensure_task_retry_on_termination_signal_guard->retry(0);
    return $job->finish(
        {
            groups_checked => scalar @groups,
            batches => scalar @batches,
            prefixes_checked => scalar @prefix_keys,
            prefix_batches => scalar @prefix_batches,
            summary_job_id => $summary->{minion_id}});
}

1;

=encoding utf8

=head1 NAME

OpenQA::Task::Job::Crosscheck - Crosscheck the results in the database against the filesystem

=head1 SYNOPSIS

    $app->plugin('OpenQA::Task::Job::Crosscheck');

=head1 DESCRIPTION

L<OpenQA::Task::Job::Crosscheck> registers the C<crosscheck_results_consistency> Minion task. Its parent job
chunks the job groups and the result prefix directories of the results and the archives into batches. A group
batch reports jobs whose results are recorded as cleaned but that still have a directory, and jobs whose results
are recorded as present but that have no directory. A prefix batch reports directories without a job row and
directories that are not the place their job row records. A summary job aggregates the counts of all batches into
the note of the parent job. It is a read-only integrity check by default: nothing is deleted or repaired. Only a
run that is started with C<repair> set removes the directories it reports as C<cleaned_with_dir> or C<orphan_dirs>,
counts them as C<repaired> and logs each removal.

The function C<enqueue_if_due> is the entry point for the systemd timer: it enqueues a run unless the
C<[cleanup] crosscheck> switch is off or a run finished within C<[cleanup] crosscheck_interval_days> days.

=cut
