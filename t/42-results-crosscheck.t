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

my $parent = run_parent;
my $parent_id = $parent->{id};

subtest 'parent job chunking and scheduling' => sub {
    is $parent->{state}, 'finished', 'parent job finished';
    is $parent->{result}{groups_checked}, 3, 'all groups scheduled';
    is $parent->{result}{batches}, 2, 'groups chunked into batches of 2';
    is $parent->{notes}{crosscheck}{batches}, 2, 'batch count noted';
    ok defined $parent->{result}{summary_job_id}, 'summary job enqueued';

    my @scheduled = minion_jobs('crosscheck_results_consistency', ['inactive']);
    is scalar @scheduled, 3, 'two group batches and one summary job enqueued';
    is $scheduled[0]{priority}, -100, 'group batch runs below the daily cleanup priority';
    is $scheduled[1]{priority}, -100, 'second group batch runs below the daily cleanup priority';
    is_deeply [map { [@{$_->{args}[0]{group_ids}}] } @scheduled[0, 1]],
      [[$alpha->id, $beta->id], [$gamma->id]], 'groups chunked in ascending ID order';
    is $scheduled[2]{args}[0]{phase}, 'summary', 'summary job phase';
    is_deeply $scheduled[2]{parents}, [$scheduled[0]{id}, $scheduled[1]{id}],
      'summary job waits for both group batches';
    is $scheduled[2]{priority}, -100, 'summary job runs below the daily cleanup priority';
    is $scheduled[2]{args}[0]{parent_job_id}, $parent_id, 'summary job refers to the parent job';
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
    is_deeply $summary,
      {
        checked_jobs => 8,
        cleaned_with_dir => 1,
        results_without_dir => 2,
        groups_checked => 3,
        samples => [$cleaned_with_dir->{dir}, $results_without_dir->{dir}, 'job ' . $beta_without_result_dir->{job}->id]
      },
      'parent note aggregates counts and sample paths of all batches';
    is $summary_job->{notes}{crosscheck_summary}{checked_jobs}, 8, 'summary job notes the same counts';
};

subtest 'cursor records the last processed group' => sub {
    is_deeply decode_json($cache_file_path->slurp), {last_group_id => $gamma->id},
      'cursor file written after the last batch';
};

subtest 'round-robin resumes after the last processed group' => sub {
    $cache_file_path->spew(encode_json({last_group_id => $alpha->id}));
    my $resumed = run_parent;
    is $resumed->{result}{batches}, 2, 'same number of batches on the resumed run';
    my @scheduled = minion_jobs('crosscheck_results_consistency', ['inactive']);
    is_deeply [map { [@{$_->{args}[0]{group_ids}}] } @scheduled[0, 1]], [[$beta->id, $gamma->id], [$alpha->id]],
      'groups rotated to continue after the last processed group';
    perform_minion_jobs($app->minion);
    is decode_json($cache_file_path->slurp)->{last_group_id}, $alpha->id, 'cursor advanced to the last group processed';
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

subtest 'no job groups present' => sub {
    $schema->txn_begin;
    $schema->resultset('JobGroups')->delete;
    my $job = run_parent;
    is $job->{result}, 'Done, no job groups present', 'nothing to check';
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

done_testing();
