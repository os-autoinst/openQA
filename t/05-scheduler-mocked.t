#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN { $ENV{OPENQA_SCHEDULER_STARVATION_PROTECTION_PRIORITY_OFFSET} = 5 }

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Test::Database;
use Test::Output 'combined_like';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::Log;
use OpenQA::Constants qw(WEBSOCKET_API_VERSION);
use OpenQA::Jobs::Constants;
use OpenQA::Test::TimeLimit '10';
use Test::MockModule;

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $jobs = $schema->resultset('Jobs');
my $workers = $schema->resultset('Workers');

# conduct tests with mocked scheduled jobs and free workers
my $mock = Test::MockModule->new('OpenQA::Scheduler::Model::Jobs');
my @mocked_common_cluster_info = (directly_chained_children => []);
my %mocked_cluster_info = (1 => {@mocked_common_cluster_info});
my @mocked_common_job_info = (
    priority => 20,
    state => SCHEDULED,
    worker_classes => ['qemu_x86_64'],
    cluster_jobs => \%mocked_cluster_info,
);
my %mocked_jobs = (1 => {id => 1, test => 'parallel-parent', @mocked_common_job_info});
my @worker_fields = (host => 'testworker', properties => [{key => 'WORKER_CLASS', value => 'qemu_x86_64'}]);
my @mocked_free_workers = map { $workers->create({@worker_fields, instance => $_}) } 1 .. 3;
my $spare_worker = pop @mocked_free_workers;
$mock->redefine(determine_online_workers => sub { \@mocked_free_workers });
$mock->redefine(determine_scheduled_jobs => sub { shift->scheduled_jobs(\%mocked_jobs); \%mocked_jobs });

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'debug'));

subtest 'error cases' => sub {
    my $allocated;

    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/Failed to retrieve jobs \(1\) in the DB, reason: only got 0 jobs/, 'job not present in DB';
    is_deeply $allocated, [], 'no job allocated (1)' or always_explain $allocated;

    my $job = $jobs->create({id => 1, state => ASSIGNED, TEST => $mocked_jobs{1}->{test}});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/1.*no longer scheduled, skipping/, 'skippinng job which is no longer scheduled';
    is_deeply $allocated, [], 'no job allocated (2)' or always_explain $allocated;

    $job->update({state => SCHEDULED, assigned_worker_id => $mocked_free_workers[0]->id});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/Worker already got jobs, skipping/, 'skippinng if worker already has jobs';
    is_deeply $allocated, [], 'no job allocated (2)' or always_explain $allocated;

    $job->update({assigned_worker_id => $spare_worker->id});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/1.*already a worker assigned, skipping/, 'skippinng job which has already worker assigned';
    is_deeply $allocated, [], 'no job allocated (3)' or always_explain $allocated;
};

subtest 'starvation of parallel jobs prevented' => sub {
    # extend mocked jobs to make a cluster of 3 parallel jobs
    # note: There are still only 2 mocked workers so the cluster can not be assigned.
    $mocked_jobs{$_} = {id => $_, test => "parallel-child-$_", @mocked_common_job_info} for (2, 3);
    $mocked_cluster_info{1} = {@mocked_common_cluster_info, parallel_children => [2, 3]};
    $mocked_cluster_info{$_} = {@mocked_common_cluster_info, parallel_parents => [1]} for (2, 3);

    # create DB entries for mocked parallel jobs
    my $parent_job = $jobs->find(1);
    $parent_job->update({state => SCHEDULED, assigned_worker_id => undef});
    my $first_child_job = $jobs->create({id => 2, state => SCHEDULED, TEST => $mocked_jobs{2}->{test}});
    my $second_child_job = $jobs->create({id => 3, state => SCHEDULED, TEST => $mocked_jobs{3}->{test}});

    # run the scheduler; parallel parent supposed to be prioritized
    my $online_workers = OpenQA::Scheduler::Model::Jobs::determine_online_workers();
    my $allocated_workers;
    combined_like { $allocated_workers = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs($online_workers) }
    qr/Need to schedule 3 parallel jobs for job 1.*Discarding job [123].*Discarding job [123]/s,
      'discarding jobs due to incomplete parallel cluster';
    is $mocked_jobs{1}->{priority_offset}, 10, 'priority of parallel parent increased (once per child)';
    is_deeply $allocated_workers, {}, 'no workers "held" so far while still increased prio'
      or always_explain $allocated_workers;
    like $mocked_jobs{1}->{current_reason}, qr/no matching worker.*parallel.*free/, 'reason assigned for job 1';
    like $mocked_jobs{$_}->{current_reason}, qr/no matching worker.*free/, "reason assigned for job $_" for (2, 3);

    # run the scheduler again assuming highest prio for parallel parent; worker supposed to be "held"
    $mocked_jobs{1}->{priority} = 0;
    combined_like { ($allocated_workers) = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs($online_workers) }
    qr/Holding worker .* for job [123] to avoid starvation.*Holding worker .* for job [123] to avoid starvation/s,
      'holding 2 workers (for 2 of our parallel jobs while 3rd worker is unavailable)';
    is_deeply [sort keys %$allocated_workers], [map { $_->id } @mocked_free_workers], 'both free workers "held"';
    ok $_ >= 1 && $_ <= 3, "worker held for expected job ($_)" for values %$allocated_workers;
};

subtest 'partially blocked clusters are not scheduled' => sub {
    # assume parallel child with ID 2 is blocked by removing it from the set of mocked jobs
    delete $mocked_jobs{2};

    my ($allocated_workers, $allocated_jobs);
    my $online_workers = OpenQA::Scheduler::Model::Jobs::determine_online_workers();
    combined_like {
        ($allocated_workers, $allocated_jobs)
          = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs($online_workers)
    }
    qr/Skipping job .* because dependent jobs are not ready/, 'skipping job if dependent jobs not ready';
    is_deeply $allocated_jobs, {}, 'no jobs allocated' or always_explain $allocated_jobs;
    is_deeply $allocated_workers, {}, 'no workers allocated' or always_explain $allocated_workers;
};

subtest 'scheduling reason when workers are busy' => sub {
    my $job_id = 1;
    $_->update({job_id => $job_id++}) for @mocked_free_workers;
    my ($allocated_workers, $allocated_jobs);
    combined_like {
        ($allocated_workers, $allocated_jobs) = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs()
    }
    qr/Skipping 2 jobs because of no free workers for requested worker classes/, 'logging busy workers';
    is $mocked_jobs{1}->{current_reason}, 'no free workers for class qemu_x86_64',
      'scheduling reason is busy workers when workers are online but not free';

    $_->update({job_id => undef}) for @mocked_free_workers;
    my $jobinfo = $mocked_jobs{1};
    my $online_workers = OpenQA::Scheduler::Model::Jobs::determine_online_workers();
    my $temp_matching = OpenQA::Scheduler::Model::Jobs::_matching_workers($jobinfo, $online_workers);
    is_deeply $temp_matching, \@mocked_free_workers, 'matching workers found without optional parameters';
};

subtest 'worker class parallel limits' => sub {
    # Clean up previous mocked data
    $jobs->delete_all;
    $workers->delete_all;

    # Clear cached scheduled jobs
    OpenQA::Scheduler::Model::Jobs->singleton->scheduled_jobs({});

    # Create two workers with WORKER_CLASS = 'foo,bar:limit=1'
    my $w1 = $workers->create(
        {
            host => 'worker1',
            instance => 1,
            properties => [{key => 'WEBSOCKET_API_VERSION', value => WEBSOCKET_API_VERSION}],
        });
    $w1->set_property(WORKER_CLASS => 'foo,bar:limit=1');

    my $w2 = $workers->create(
        {
            host => 'worker2',
            instance => 2,
            properties => [{key => 'WEBSOCKET_API_VERSION', value => WEBSOCKET_API_VERSION}],
        });
    $w2->set_property(WORKER_CLASS => 'foo,bar:limit=1');

    # Check check_class parsing
    ok $w1->check_class('foo'), 'worker matches class foo even with limit suffix';
    ok $w1->check_class('bar'), 'worker matches class bar even with limit suffix';
    ok !$w1->check_class('baz'), 'worker does not match class baz';

    # Setup mocked jobs for scheduler
    my %test_mocked_jobs = (
        4 => {
            id => 4,
            test => 'test-job-4',
            priority => 20,
            state => SCHEDULED,
            worker_classes => ['foo'],
            cluster_jobs => {4 => {directly_chained_children => []}},
        },
        5 => {
            id => 5,
            test => 'test-job-5',
            priority => 21,
            state => SCHEDULED,
            worker_classes => ['foo'],
            cluster_jobs => {5 => {directly_chained_children => []}},
        },
    );

    # Create corresponding DB entries for these scheduled jobs
    my $j4 = $jobs->create({id => 4, state => SCHEDULED, TEST => 'test-job-4'});
    $j4->settings->create({key => 'WORKER_CLASS', value => 'foo'});

    my $j5 = $jobs->create({id => 5, state => SCHEDULED, TEST => 'test-job-5'});
    $j5->settings->create({key => 'WORKER_CLASS', value => 'foo'});

    my @test_online_workers = ($w1, $w2);
    $mock->redefine(determine_online_workers => sub { \@test_online_workers });
    $mock->redefine(determine_scheduled_jobs => sub { shift->scheduled_jobs(\%test_mocked_jobs); \%test_mocked_jobs });

    # Explicitly set the scheduled_jobs cache
    OpenQA::Scheduler::Model::Jobs->singleton->scheduled_jobs(\%test_mocked_jobs);

    # Run scheduler
    my ($allocated_workers, $allocated_jobs);
    combined_like {
        ($allocated_workers, $allocated_jobs) = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs();
    }
    qr/Need to schedule 1 parallel jobs for job 4.*Need to schedule 1 parallel jobs for job 5/s,
      'logging parallel jobs for job 4 and 5';

    # Only 1 job of class foo should be allocated because both workers share the limit for bar:limit=1
    is scalar(keys %$allocated_jobs), 1, 'Only one job is allocated due to bar:limit=1';
    is $test_mocked_jobs{5}->{current_reason}, 'class limit reached (bar limit is 1)',
      'correct current reason for limit failure';

    $j4->delete;
    $j5->delete;
    $w1->delete;
    $w2->delete;
};

subtest 'worker class parallel limits coverage' => sub {
    # Clean up previous mocked data
    $jobs->delete_all;
    $workers->delete_all;

    # Clear cached scheduled jobs
    OpenQA::Scheduler::Model::Jobs->singleton->scheduled_jobs({});

    # Create two workers with WORKER_CLASS = 'foo,bar:limit=1'
    my $w1 = $workers->create(
        {
            host => 'worker1',
            instance => 1,
            properties => [{key => 'WEBSOCKET_API_VERSION', value => WEBSOCKET_API_VERSION}],
        });
    $w1->set_property(WORKER_CLASS => 'foo,bar:limit=1');

    my $w2 = $workers->create(
        {
            host => 'worker2',
            instance => 2,
            properties => [{key => 'WEBSOCKET_API_VERSION', value => WEBSOCKET_API_VERSION}],
        });
    $w2->set_property(WORKER_CLASS => 'foo,bar:limit=1');

    # Create an executing (running) job assigned to w1, and mark w1 as busy
    my $j3 = $jobs->create({id => 3, state => RUNNING, TEST => 'test-job-running', assigned_worker_id => $w1->id});
    $w1->update({job_id => 3});

    # Setup mocked jobs for scheduler: Job 4 is part of a cluster with Job 3
    my %test_mocked_jobs = (
        4 => {
            id => 4,
            test => 'test-job-4',
            priority => 20,
            state => SCHEDULED,
            worker_classes => ['foo'],
            cluster_jobs => {3 => {directly_chained_children => []}, 4 => {directly_chained_children => []}},
        },
    );

    # Create corresponding DB entries for these scheduled jobs
    my $j4 = $jobs->create({id => 4, state => SCHEDULED, TEST => 'test-job-4'});
    $j4->settings->create({key => 'WORKER_CLASS', value => 'foo'});

    my @test_online_workers = ($w1, $w2);
    $mock->redefine(determine_online_workers => sub { \@test_online_workers });
    $mock->redefine(determine_scheduled_jobs => sub { shift->scheduled_jobs(\%test_mocked_jobs); \%test_mocked_jobs });

    # Explicitly set the scheduled_jobs cache
    OpenQA::Scheduler::Model::Jobs->singleton->scheduled_jobs(\%test_mocked_jobs);

    # Run scheduler
    my ($allocated_workers, $allocated_jobs) = OpenQA::Scheduler::Model::Jobs->singleton->_allocate_jobs();

    # Check that Job 4 was successfully allocated via sibling allocation
    ok exists $allocated_jobs->{4}, 'Job 4 allocated via sibling of running Job 3';

    # Clean up
    $j3->delete;
    $j4->delete;
    $w1->delete;
    $w2->delete;
};

done_testing();
