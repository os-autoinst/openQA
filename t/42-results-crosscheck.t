#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
require OpenQA::Test::Database;
use OpenQA::Task::Job::Crosscheck;
use OpenQA::Test::Utils qw(run_gru_job perform_minion_jobs setup_fullstack_temp_dir);
use OpenQA::Utils qw(prjdir resultdir);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File qw(path);
use Mojo::Log;
use DateTime;
use Time::Seconds;
use Test::Output qw(combined_like);
use Test::Mojo;
use Test::Warnings ':report_warnings';

setup_fullstack_temp_dir('crosscheck');
path(prjdir(), 'db')->make_path->child('db.lock')->spew('');
my $cache_file_path = path(prjdir(), 'webui', 'cache', 'crosscheck-status.json');
my $new_cache_file_path = "$cache_file_path.new";

my $schema = OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$app->log(Mojo::Log->new(level => 'warn'));
$app->config->{misc_limits}->{crosscheck_groups_per_batch} = 2;
$app->config->{misc_limits}->{crosscheck_prefixes_per_batch} = 1;

my $jobs = $schema->resultset('Jobs');
my $groups = $schema->resultset('JobGroups');

sub create_group ($name, $days) {
    $groups->create({name => $name, keep_results_in_days => $days, keep_important_results_in_days => $days});
}

# $dir_state: none (no directory), old (directory older than 24 h), young (directory just created),
# removed (result_dir recorded, directory deleted again)
sub create_job ($group, $size, $state, $dir_state) {
    my $job = $jobs->create(
        {TEST => 'crosscheck', group_id => $group->id, state => $state, result => 'passed', result_size => $size});
    $job->update({t_created => DateTime->new(year => 2020, month => 1, day => 1)});
    my $dir;
    $dir = $job->create_result_dir unless $dir_state eq 'none';
    path($dir)->remove_tree if $dir_state eq 'removed';
    my $mtime = $dir_state eq 'young' ? time : time - 10 * ONE_DAY;
    utime $mtime, $mtime, $dir if $dir;
    return {job => $job, dir => $dir};
}

sub create_job_row ($id, $size, $archived, $dir) {
    my $job = $jobs->create(
        {
            id => $id,
            TEST => 'crosscheck',
            state => 'done',
            result => 'passed',
            result_size => $size,
            archived => $archived
        });
    $job->update({result_dir => $dir->basename});
    $dir->make_path;
    utime time - 10 * ONE_DAY, time - 10 * ONE_DAY, $dir;
}

sub create_prefix_job ($dir, $size) {
    my ($id) = $dir->basename =~ /^(\d+)/;
    my $job
      = $jobs->create({id => 0 + $id, TEST => 'crosscheck', state => 'done', result => 'passed', result_size => $size});
    $job->create_result_dir;
    utime time - 10 * ONE_DAY, time - 10 * ONE_DAY, $dir;
}

sub create_prefix_dir ($dir, $mtime = time - 10 * ONE_DAY) {
    $dir->make_path;
    utime $mtime, $mtime, $dir;
}

sub run_parent () { run_gru_job($app, crosscheck_results_consistency => []) }

sub minion_jobs ($task, $states) {
    sort { $a->{id} <=> $b->{id} }
      @{$app->minion->backend->list_jobs(0, 100, {tasks => [$task], states => $states})->{jobs}};
}

my $alpha = create_group('alpha', 1);
my $beta = create_group('beta', 1);
my $gamma = create_group('gamma', 0);    # unlimited retention

my $cleaned_with_dir = create_job($alpha, 0, 'done', 'old');
my $results_without_dir = create_job($alpha, 100, 'done', 'removed');
my $healthy_cleaned = create_job($alpha, 0, 'done', 'none');
my $healthy_present = create_job($alpha, 100, 'done', 'old');
my $young_dir = create_job($alpha, 0, 'done', 'young');
my $non_final_job = create_job($alpha, 0, 'running', 'old');
my $beta_cleaned = create_job($beta, 0, 'done', 'none');
my $beta_present = create_job($beta, 100, 'done', 'old');
my $beta_without_result_dir = create_job($beta, 100, 'done', 'none');
my $unlimited_retention = create_job($gamma, 0, 'done', 'old');

my $prefix_cleaned_dir = path(resultdir(), '00001', '00001000-crosscheck');
my $prefix_orphan_dir = path(resultdir(), '00001', '00001001-crosscheck');
my $prefix_healthy_dir = path(resultdir(), '00001', '00001003-crosscheck');
my $prefix_young_orphan_dir = path(resultdir(), '00001', '00001002-crosscheck');
create_prefix_job($prefix_cleaned_dir, 0);
create_prefix_job($prefix_healthy_dir, 100);
create_prefix_dir($prefix_orphan_dir);
create_prefix_dir($prefix_young_orphan_dir, time);

my $archived_prefix = path(resultdir(1), '00001');
my $archived_in_archive = $archived_prefix->child('00001010-crosscheck');
my $archived_orphan = $archived_prefix->child('00001011-crosscheck');
my $archived_young = $archived_prefix->child('00001012-crosscheck');
my $archived_copy = $archived_prefix->child('00001013-crosscheck');
my $archived_in_results = path(resultdir(), '00001', '00001004-crosscheck');
my $copy_row_dir = path(resultdir(), '00001', '00001013-crosscheck');
create_job_row(1004, 100, 1, $archived_in_results);
create_job_row(1010, 100, 1, $archived_in_archive);
create_job_row(1013, 100, 0, $copy_row_dir);
create_prefix_dir($archived_orphan);
create_prefix_dir($archived_young, time);
create_prefix_dir($archived_copy);

my $parent = run_parent;
my $parent_id = $parent->{id};

subtest 'parent job chunking and scheduling' => sub {
    is $parent->{state}, 'finished', 'parent job finished';
    is $parent->{result}{groups_checked}, 3, 'all groups scheduled';
    is $parent->{result}{batches}, 2, 'groups chunked into batches of 2';
    is $parent->{notes}{crosscheck}{batches}, 2, 'batch count noted';
    ok defined $parent->{result}{summary_job_id}, 'summary job enqueued';

    my @scheduled = minion_jobs('crosscheck_results_consistency', ['inactive']);
    is scalar @scheduled, 6, 'two group batches, three prefix batches and one summary job enqueued';
    is $parent->{result}{prefixes_checked}, 3, 'prefixes of the results and the archives scheduled';
    is $parent->{result}{prefix_batches}, 3, 'prefixes chunked into batches of one prefix';
    is $parent->{notes}{crosscheck}{prefix_batches}, 3, 'prefix batch count noted';
    is $scheduled[0]{priority}, -100, 'group batch runs below the daily cleanup priority';
    is $scheduled[1]{priority}, -100, 'second group batch runs below the daily cleanup priority';
    is_deeply [map { [@{$_->{args}[0]{group_ids}}] } @scheduled[0, 1]],
      [[$alpha->id, $beta->id], [$gamma->id]], 'groups chunked in ascending ID order';
    is $scheduled[2]{args}[0]{phase}, 'prefixes', 'prefix batch phase';
    is_deeply [map { "$_->{base}/$_->{prefix}" } map { @{$_->{args}[0]{prefixes}} } @scheduled[2 .. 4]],
      [resultdir(1) . '/00001', resultdir() . '/00000', resultdir() . '/00001'],
      'prefixes of both trees chunked in ascending order';
    is $scheduled[2]{priority}, -100, 'prefix batch runs below the daily cleanup priority';
    is $scheduled[5]{args}[0]{phase}, 'summary', 'summary job phase';
    is_deeply $scheduled[5]{parents}, [map { $_->{id} } @scheduled[0 .. 4]],
      'summary job waits for all group and prefix batches';
    is $scheduled[5]{priority}, -100, 'summary job runs below the daily cleanup priority';
    is $scheduled[5]{args}[0]{parent_job_id}, $parent_id, 'summary job refers to the parent job';
};

perform_minion_jobs($app->minion);

subtest 'tier A counts reported per batch and aggregated into the parent note' => sub {
    my @finished = minion_jobs('crosscheck_results_consistency', ['finished']);
    my @batches = grep { ($_->{args}[0]{phase} // '') eq 'groups' } @finished;
    my $summary_job = (grep { ($_->{args}[0]{phase} // '') eq 'summary' } @finished)[0];
    is_deeply $batches[0]{notes}{crosscheck},
      {
        checked_jobs => 8,
        cleaned_with_dir => 1,
        results_without_dir => 2,
        groups_checked => 2,
        samples => [$cleaned_with_dir->{dir}, $results_without_dir->{dir}, 'job ' . $beta_without_result_dir->{job}->id]
      },
      'batch over alpha and beta reports the mismatching jobs only';
    is_deeply $batches[1]{notes}{crosscheck},
      {
        checked_jobs => 0,
        cleaned_with_dir => 0,
        results_without_dir => 0,
        groups_checked => 1,
        samples => []
      },
      'batch over gamma skips the group with unlimited retention';
    is $summary_job->{state}, 'finished', 'summary job finished';

    my $summary = $app->minion->job($parent_id)->info->{notes}{crosscheck_summary};
    my %counts = %$summary;
    my @samples = @{delete $counts{samples}};
    is_deeply \%counts,
      {
        checked_jobs => 8,
        cleaned_with_dir => 4,
        results_without_dir => 2,
        groups_checked => 3,
        entries_scanned => 16,
        prefixes_checked => 3,
        orphan_dirs => 2,
        archived_with_dir => 1,
        archived_copy => 1
      },
      'parent note aggregates the counts of all group and prefix batches';
    is_deeply [sort map { "$_" } @samples],
      [
        sort map { "$_" } (
            $cleaned_with_dir->{dir}, $results_without_dir->{dir}, 'job 9',
            $unlimited_retention->{dir}, $prefix_cleaned_dir, $prefix_orphan_dir,
            $archived_in_results, $archived_orphan, $archived_copy
        )
      ],
      'parent note samples cover the leftovers of the group and prefix batches';
    is $summary_job->{notes}{crosscheck_summary}{checked_jobs}, 8, 'summary job notes the same counts';
};

subtest 'cursor records the last processed group and prefix' => sub {
    is_deeply decode_json($cache_file_path->slurp),
      {last_group_id => $gamma->id, last_prefix => resultdir() . '/00001'},
      'cursor file records both cursors after the batches';
};

subtest 'tier B prefix scan reports dirs without a job row and dirs in the wrong tree' => sub {
    my @finished = minion_jobs('crosscheck_results_consistency', ['finished']);
    my @prefix_batches = grep { ($_->{args}[0]{phase} // '') eq 'prefixes' } @finished;
    is scalar @prefix_batches, 3, 'all prefix batches finished';

    my %archived_counts = %{$prefix_batches[0]{notes}{crosscheck}};
    my @archived_samples = @{delete $archived_counts{samples}};
    is_deeply \%archived_counts,
      {
        entries_scanned => 4,
        prefixes_checked => 1,
        orphan_dirs => 1,
        cleaned_with_dir => 0,
        archived_with_dir => 0,
        archived_copy => 1
      },
      'archive prefix reports the directory without a job row and the copy of a job with results in the results tree';
    is_deeply [sort map { "$_" } @archived_samples], [sort "$archived_orphan", "$archived_copy"],
      'archive prefix sample paths';

    my %results_0_counts = %{$prefix_batches[1]{notes}{crosscheck}};
    my @results_0_samples = @{delete $results_0_counts{samples}};
    is_deeply \%results_0_counts,
      {
        entries_scanned => 6,
        prefixes_checked => 1,
        orphan_dirs => 0,
        cleaned_with_dir => 2,
        archived_with_dir => 0,
        archived_copy => 0
      },
      'prefix 00000 counts the jobs recorded as cleaned and skips young dirs and non-final jobs';
    is_deeply [sort map { "$_" } @results_0_samples],
      [sort $cleaned_with_dir->{dir}, $unlimited_retention->{dir}],
      'prefix 00000 sample paths';

    my %results_1_counts = %{$prefix_batches[2]{notes}{crosscheck}};
    my @results_1_samples = @{delete $results_1_counts{samples}};
    is_deeply \%results_1_counts,
      {
        entries_scanned => 6,
        prefixes_checked => 1,
        orphan_dirs => 1,
        cleaned_with_dir => 1,
        archived_with_dir => 1,
        archived_copy => 0
      },
      'prefix 00001 counts the cleaned job, the orphan dir and the archived job left in the results tree';
    is_deeply [sort map { "$_" } @results_1_samples],
      [sort "$prefix_cleaned_dir", "$prefix_orphan_dir", "$archived_in_results"],
      'prefix 00001 sample paths';
};

subtest 'round-robin resumes after the last processed group and prefix' => sub {
    $cache_file_path->spew(encode_json({last_group_id => $alpha->id, last_prefix => resultdir(1) . '/00001'}));
    my $resumed = run_parent;
    is $resumed->{result}{batches}, 2, 'same number of group batches on the resumed run';
    is $resumed->{result}{prefix_batches}, 3, 'same number of prefix batches on the resumed run';
    my @scheduled = minion_jobs('crosscheck_results_consistency', ['inactive']);
    is_deeply [map { [@{$_->{args}[0]{group_ids}}] } @scheduled[0, 1]], [[$beta->id, $gamma->id], [$alpha->id]],
      'groups rotated to continue after the last processed group';
    is_deeply [map { "$_->{base}/$_->{prefix}" } map { @{$_->{args}[0]{prefixes}} } @scheduled[2 .. 4]],
      [resultdir() . '/00000', resultdir() . '/00001', resultdir(1) . '/00001'],
      'prefixes rotated to continue after the last processed prefix';
    perform_minion_jobs($app->minion);
    is decode_json($cache_file_path->slurp)->{last_group_id}, $alpha->id, 'cursor advanced to the last group processed';
    is decode_json($cache_file_path->slurp)->{last_prefix}, resultdir(1) . '/00001',
      'cursor advanced to the last prefix processed';
};

subtest 'prefix appearing between runs is covered by the next run' => sub {
    my $dir = path(resultdir(), '00002', '00002000-crosscheck')->make_path;
    utime time - 10 * ONE_DAY, time - 10 * ONE_DAY, $dir;
    my $resumed = run_parent;
    is $resumed->{result}{prefixes_checked}, 4, 'new prefix scheduled';
    my @scheduled = minion_jobs('crosscheck_results_consistency', ['inactive']);
    is_deeply [map { "$_->{base}/$_->{prefix}" } map { @{$_->{args}[0]{prefixes}} } @scheduled[2 .. 5]],
      [resultdir() . '/00000', resultdir() . '/00001', resultdir() . '/00002', resultdir(1) . '/00001'],
      'prefix batches continue after the last processed prefix';
    perform_minion_jobs($app->minion);
    is decode_json($cache_file_path->slurp)->{last_prefix}, resultdir(1) . '/00001',
      'cursor advanced past the new prefix to the last batch';
    path(resultdir(), '00002')->remove_tree;
};

subtest 'group deleted between the parent job and its batch is skipped' => sub {
    my $batch = run_gru_job($app, crosscheck_results_consistency => [{phase => 'groups', group_ids => [999999]}]);
    is $batch->{state}, 'finished', 'batch job finished';
    is $batch->{notes}{crosscheck}{groups_checked}, 0, 'missing group not counted';
    is $batch->{notes}{crosscheck}{checked_jobs}, 0, 'no jobs checked for the missing group';
    $cache_file_path->spew(encode_json({last_group_id => $gamma->id}));
};

subtest 'invalid phase fails the job' => sub {
    my $job;
    combined_like { $job = run_gru_job($app, crosscheck_results_consistency => [{phase => 'nonsense'}]) }
    qr/The specified crosscheck phase is invalid/, 'job error logged';
    is $job->{state}, 'failed', 'job fails';
    is $job->{result}{error}, 'The specified crosscheck phase is invalid.', 'error reported';
};

subtest 'crosscheck skips while the daily cleanup is running' => sub {
    my $cleanup_id = $app->minion->enqueue(limit_results_and_logs => []);
    my $job = run_parent;
    is $job->{state}, 'finished', 'crosscheck job finished without doing work';
    is $job->{result}, 'Skipping, there are still 1 inactive/active cleanup jobs', 'skipping reported';
    $app->minion->job($cleanup_id)->remove;
};

subtest 'no job groups and no results present' => sub {
    $schema->txn_begin;
    $schema->resultset('JobGroups')->delete;
    my $hidden = path(resultdir(), 'hidden_prefixes');
    my %trees = (results => resultdir(), archives => resultdir(1));
    for my $tree (sort keys %trees) {
        $hidden->child($tree)->make_path;
        $_->move_to($hidden->child($tree, $_->basename))
          for grep { $_->basename =~ /^\d{5}$/ } @{path($trees{$tree})->list({dir => 1})};
    }
    my $job = run_parent;
    is $job->{result}, 'Done, no job groups and no results present', 'nothing to check';
    for my $tree (sort keys %trees) {
        $_->move_to(path($trees{$tree}, $_->basename)) for @{path($hidden, $tree)->list({dir => 1})};
    }
    $hidden->remove_tree;
    $schema->txn_rollback;
};

subtest 'unreadable cursor is ignored with a warning' => sub {
    $cache_file_path->spew('{"invalid JSON');
    combined_like { run_parent } qr/Unable to read crosscheck status from \Q$cache_file_path\E:/s,
      'warning logged on read failure';
};

subtest 'unwritable cursor is reported with a warning' => sub {
    path($new_cache_file_path)->make_path;
    combined_like { run_parent; perform_minion_jobs($app->minion) }
    qr/Unable to write crosscheck status to \Q$cache_file_path\E:/s, 'warning logged on write failure';
    path($new_cache_file_path)->remove_tree;
};

subtest 'sample paths are capped' => sub {
    $cache_file_path->spew(encode_json({last_group_id => $gamma->id}));
    my $group = create_group('delta', 1);
    create_job($group, 0, 'done', 'old') for 1 .. 25;
    my $batch = run_gru_job($app, crosscheck_results_consistency => [{phase => 'groups', group_ids => [$group->id]}]);
    is scalar @{$batch->{notes}{crosscheck}{samples}}, 20, 'sample list capped at 20 paths';
    is $batch->{notes}{crosscheck}{cleaned_with_dir}, 25, 'all mismatching jobs counted';
    $group->delete;
};

subtest 'enqueue_if_due only enqueues an enabled run that is due' => sub {
    perform_minion_jobs($app->minion);
    my $enqueue_if_due = \&OpenQA::Task::Job::Crosscheck::enqueue_if_due;
    $app->config->{cleanup}{crosscheck_interval_days} = 30;

    $app->config->{cleanup}{crosscheck} = 0;
    is $enqueue_if_due->($app), undef, 'disabled crosscheck not enqueued';

    $app->config->{cleanup}{crosscheck} = 1;
    is $enqueue_if_due->($app), undef, 'run finished minutes ago suppresses the enqueue within the interval';

    $app->config->{cleanup}{crosscheck_interval_days} = 0;
    my $first = $enqueue_if_due->($app);
    ok $first, 'zero interval enqueues on every tick';
    my $enqueued = $app->minion->job($first)->info;
    is $enqueued->{priority}, -100, 'enqueued run uses the lowest priority';
    is_deeply $enqueued->{args}, [], 'enqueued run takes no arguments';

    my $worker = $app->minion->worker->register;
    $worker->dequeue(0, {id => $first})->execute;
    $worker->unregister;
    is $app->minion->job($first)->info->{state}, 'finished', 'enqueued run performs the crosscheck';

    $app->config->{cleanup}{crosscheck_interval_days} = 30;
    is $enqueue_if_due->($app), undef, 'the run that just finished suppresses the next enqueue';
};

done_testing();
