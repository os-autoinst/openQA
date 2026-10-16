#!/usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Most;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;
use Mojo::Date;
use DateTime;

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $workers = $schema->resultset('Workers');
my $jobs = $schema->resultset('Jobs');

subtest 'worker last_job_finished and batched last_jobs_finished_per_worker' => sub {
    my $now = DateTime->now(time_zone => 'UTC');
    my $worker_no_jobs = $workers->create({host => 'host-fresh', instance => 1, t_seen => $now});
    is $worker_no_jobs->last_job_finished, undef, 'worker without completed jobs reports undef for last_job_finished';

    my $worker_active = $workers->create({host => 'host-active', instance => 1, t_seen => $now});
    my $older_time = $now->clone->subtract(days => 2);
    my $newer_time = $now->clone->subtract(hours => 2);

    my $job_older = $jobs->create(
        {
            TEST => 'test-older',
            assigned_worker_id => $worker_active->id,
            state => DONE,
            result => PASSED,
        });
    $job_older->update({t_finished => $older_time});
    is $worker_active->last_job_finished, $older_time->strftime('%Y-%m-%dT%H:%M:%SZ'),
      'worker with single finished job reports that job timestamp';

    my $job_newer = $jobs->create(
        {
            TEST => 'test-newer',
            assigned_worker_id => $worker_active->id,
            state => DONE,
            result => PASSED,
        });
    $job_newer->update({t_finished => $newer_time});
    is $worker_active->last_job_finished, $newer_time->strftime('%Y-%m-%dT%H:%M:%SZ'),
      'worker with multiple finished jobs reports most recent t_finished';

    is_deeply $workers->last_jobs_finished_per_worker([]), {},
      'batched last_jobs_finished_per_worker returns empty hash for empty worker id list';

    my $batched = $workers->last_jobs_finished_per_worker([$worker_no_jobs->id, $worker_active->id]);
    is $batched->{$worker_no_jobs->id}, undef,
      'batched lookup does not contain finished timestamp for worker without jobs';
    is $batched->{$worker_active->id}, $newer_time->strftime('%Y-%m-%dT%H:%M:%SZ'),
      'batched lookup returns latest finished timestamp for active worker';
};

subtest 'host_activity_summary and unused filtering' => sub {
    my $now = DateTime->now(time_zone => 'UTC');
    my $time_5d = $now->clone->subtract(days => 5);
    my $time_20d = $now->clone->subtract(days => 20);
    my $time_40d = $now->clone->subtract(days => 40);

    my $dead_time = $now->clone->subtract(days => 1);

    my $h_active_1 = $workers->create({host => 'summary-active', instance => 1, t_seen => $now});
    $h_active_1->set_property(WORKER_CLASS => 'qemu_x86_64');
    my $h_active_2 = $workers->create({host => 'summary-active', instance => 2, t_seen => $now});
    $h_active_2->set_property(WORKER_CLASS => 'qemu_x86_64,qemu_i586:limit=2');

    my $j1 = $jobs->create({TEST => 'test-5d', assigned_worker_id => $h_active_1->id, state => DONE, result => PASSED});
    $j1->update({t_finished => $time_5d});
    my $j2
      = $jobs->create({TEST => 'test-20d', assigned_worker_id => $h_active_2->id, state => DONE, result => PASSED});
    $j2->update({t_finished => $time_20d});

    my $h_dormant = $workers->create({host => 'summary-dormant', instance => 1, t_seen => $now});
    $h_dormant->set_property(WORKER_CLASS => 'qemu_aarch64');
    my $j3
      = $jobs->create({TEST => 'test-dormant', assigned_worker_id => $h_dormant->id, state => DONE, result => PASSED});
    $j3->update({t_finished => $time_20d});

    my $h_never = $workers->create({host => 'summary-never', instance => 1, t_seen => $now});
    $h_never->set_property(WORKER_CLASS => 'qemu_ppc64le');

    my $h_offline = $workers->create({host => 'summary-offline', instance => 1, t_seen => $dead_time});
    my $j4
      = $jobs->create({TEST => 'test-offline', assigned_worker_id => $h_offline->id, state => DONE, result => PASSED});
    $j4->update({t_finished => $time_40d});

    my $busy_job = $jobs->create({TEST => 'test-busy', state => RUNNING});
    my $h_busy = $workers->create({host => 'summary-busy', instance => 1, t_seen => $now, job_id => $busy_job->id});

    my @scope_workers = ($h_active_1, $h_active_2, $h_dormant, $h_never, $h_offline, $h_busy);
    my $scope_rs = $workers->search({id => {-in => [map { $_->id } @scope_workers]}});

    my $summary_14d = $scope_rs->host_activity_summary(14);

    my @test_cases = (
        {
            desc => 'active host with recent job has correct counts and is not idle',
            host => 'summary-active',
            expected_total => 2,
            expected_online => 2,
            expected_recent_jobs => 1,
            expected_is_idle => 0,
            expected_classes => ['qemu_i586', 'qemu_x86_64'],
            has_finished => 1,
        },
        {
            desc => 'dormant host with only old job is flagged idle for 14-day window',
            host => 'summary-dormant',
            expected_total => 1,
            expected_online => 1,
            expected_recent_jobs => 0,
            expected_is_idle => 1,
            expected_classes => ['qemu_aarch64'],
            has_finished => 1,
        },
        {
            desc => 'never-used host has zero recent jobs, undefined last finished, and is idle',
            host => 'summary-never',
            expected_total => 1,
            expected_online => 1,
            expected_recent_jobs => 0,
            expected_is_idle => 1,
            expected_classes => ['qemu_ppc64le'],
            has_finished => 0,
        },
        {
            desc => 'busy host running a job is not flagged as idle',
            host => 'summary-busy',
            expected_total => 1,
            expected_online => 1,
            expected_recent_jobs => 0,
            expected_is_idle => 0,
            expected_classes => [],
            has_finished => 0,
        },
    );

    for my $case (@test_cases) {
        my $data = $summary_14d->{$case->{host}};
        ok $data, "$case->{desc}: host entry exists";
        is $data->{total_instances}, $case->{expected_total}, "$case->{desc}: total instances match";
        is $data->{online_instances}, $case->{expected_online}, "$case->{desc}: online instances match";
        is $data->{jobs_count_recent}, $case->{expected_recent_jobs}, "$case->{desc}: recent jobs count matches";
        is $data->{is_idle}, $case->{expected_is_idle}, "$case->{desc}: is_idle matches";
        is_deeply $data->{worker_classes}, $case->{expected_classes}, "$case->{desc}: worker classes match";
        if ($case->{has_finished}) {
            ok defined $data->{last_job_finished}, "$case->{desc}: last_job_finished is defined";
            ok defined $data->{idle_seconds}, "$case->{desc}: idle_seconds is defined";
        }
        else {
            is $data->{last_job_finished}, undef, "$case->{desc}: last_job_finished is undef";
            is $data->{idle_seconds}, undef, "$case->{desc}: idle_seconds is undef";
        }
    }

    my @unused_workers_online = $scope_rs->find_unused_workers(threshold_days => 14, online_only => 1);
    my @unused_worker_ids = sort { $a <=> $b } map { $_->id } @unused_workers_online;
    my @expected_unused_worker_ids = sort { $a <=> $b } ($h_active_2->id, $h_dormant->id, $h_never->id);
    is_deeply \@unused_worker_ids, \@expected_unused_worker_ids,
      'find_unused_workers online only returns dormant and never-used workers';

    my @unused_workers_all = $scope_rs->find_unused_workers(threshold_days => 14, online_only => 0);
    my @all_unused_worker_ids = sort { $a <=> $b } map { $_->id } @unused_workers_all;
    my @expected_all_unused_ids = sort { $a <=> $b } ($h_active_2->id, $h_dormant->id, $h_never->id, $h_offline->id);
    is_deeply \@all_unused_worker_ids, \@expected_all_unused_ids,
      'find_unused_workers offline included returns offline dormant worker as well';

    my @unused_hosts_online = $scope_rs->find_unused_hosts(threshold_days => 14, online_only => 1);
    my @unused_host_names = sort map { $_->{host} } @unused_hosts_online;
    is_deeply \@unused_host_names, ['summary-dormant', 'summary-never'],
      'find_unused_hosts online only returns online dormant and never-used hosts';

    my @unused_hosts_all = $scope_rs->find_unused_hosts(threshold_days => 14, online_only => 0);
    my @all_unused_host_names = sort map { $_->{host} } @unused_hosts_all;
    is_deeply \@all_unused_host_names, ['summary-dormant', 'summary-never', 'summary-offline'],
      'find_unused_hosts offline included returns offline dormant host as well';

    my $empty_rs = $workers->search({id => -1});
    is_deeply $empty_rs->host_activity_summary, {}, 'host_activity_summary returns empty hash for empty resultset';
    is_deeply [$empty_rs->find_unused_workers], [], 'find_unused_workers returns empty list for empty resultset';
    is_deeply [$empty_rs->find_unused_hosts], [], 'find_unused_hosts returns empty list for empty resultset';
};

done_testing;
