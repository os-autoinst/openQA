#!/usr/bin/env perl

# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN { $ENV{OPENQA_SCHEDULER_STARVATION_PROTECTION_PRIORITY_OFFSET} = 5 }

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKER_COMMAND_GRAB_JOBS);
use OpenQA::Test::Database;
use Test::Output 'combined_like';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::Log;
use OpenQA::WebSockets::Client;
use OpenQA::WebAPI::Controller::API::V1::Worker;
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Test::Utils 'embed_server_for_testing';
use Test::MockModule;

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $jobs = $schema->resultset('Jobs');
my $workers = $schema->resultset('Workers');
my $t = Test::Mojo->new('OpenQA::WebAPI');
embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client => OpenQA::WebSockets::Client->singleton,
);
OpenQA::Scheduler::Model::Jobs->singleton->shuffle_workers(0);

# define test helper
my %default_job_settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    MACHINE => 'RainbowPC',
    ARCH => 'x86_64',
    NICTYPE => 'tap',
);
sub _job_create {
    my ($settings, $parallel_jobs, $start_after_jobs, $start_directly_after_jobs) = @_;
    $settings = {%default_job_settings, TEST => $settings} unless ref $settings;
    $settings->{_PARALLEL_JOBS} = $parallel_jobs if $parallel_jobs;
    $settings->{_START_AFTER_JOBS} = $start_after_jobs if $start_after_jobs;
    $settings->{_START_DIRECTLY_AFTER_JOBS} = $start_directly_after_jobs if $start_directly_after_jobs;
    my $job = $jobs->create_from_settings($settings);
    $job->discard_changes;    # reload all values from database so we can check against default values
    return $job;
}
sub _jobs_update_state {
    my ($jobs, $state, $result) = @_;
    for my $job (@$jobs) {
        $job->state($state);
        $job->result($result) if $result;
        $job->update;
    }
}
sub _job_deps { $jobs->find(shift, {prefetch => [qw(settings parents children)]})->to_hash(deps => 1) }
sub _schedule {
    my $scheduling_info = OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    _jobs_update_state([$jobs->find($_->{job})], RUNNING) for @$scheduling_info;
}

# mock sending jobs to a worker
my $jobs_result_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my $mock_send_called;
my $sent = {};
$jobs_result_mock->redefine(
    ws_send => sub {
        my ($self, $worker) = @_;
        my $hashref = $self->prepare_for_work($worker);
        _jobs_update_state([$self], RUNNING);
        $hashref->{assigned_worker_id} = $worker->id;
        $sent->{$worker->id} = {worker => $worker, job => $self, jobhash => $hashref};
        $sent->{job}->{$self->id} = {worker => $worker, job => $self, jobhash => $hashref};
        $mock_send_called++;
        return {state => {msg_sent => 1}};
    });

# create workers
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;
my %workercaps = (
    cpu_modelname => 'Rainbow CPU',
    cpu_arch => 'x86_64',
    cpu_opmode => '32-bit, 64-bit',
    mem_max => '4096',
    worker_class => 'qemu_x86_64',
    isotovideo_interface_version => WEBSOCKET_API_VERSION,
    websocket_api_version => WEBSOCKET_API_VERSION,
);
my @worker_ids = map { $c->_register($schema, 'host', "$_", \%workercaps) } (1 .. 6);

subtest 'assign multiple jobs to worker' => sub {
    my $worker = $workers->first;
    my $worker_id = $worker->id;
    my @job_ids = (99926, 99927, 99928);
    my @jobs = $jobs->search({id => {-in => \@job_ids}})->all;
    my @job_sequence = (99927, [99928, 99926]);

    # use fake web socket connection
    my $fake_ws_tx = OpenQA::Test::FakeWebSocketTransaction->new;
    my $sent_messages = $fake_ws_tx->sent_messages;
    OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id}->{tx} = $fake_ws_tx;

    OpenQA::Scheduler::Model::Jobs->new->_assign_multiple_jobs_to_worker(\@jobs, $worker, \@job_sequence, \@job_ids);

    is(scalar @$sent_messages, 1, 'exactly one message sent');
    is(ref(my $json = $sent_messages->[0]->{json}), 'HASH', 'json data sent');
    is(ref(my $job_info = $json->{job_info}), 'HASH', 'job info sent') or diag explain $sent_messages;
    is($json->{type}, WORKER_COMMAND_GRAB_JOBS, 'event type present');
    is($job_info->{assigned_worker_id}, $worker_id, 'worker ID present');
    is_deeply($job_info->{ids}, \@job_ids, 'job IDs present');
    is_deeply($job_info->{sequence}, \@job_sequence, 'job sequence present');
    is_deeply([sort keys %{$job_info->{data}}], \@job_ids, 'data for all jobs present');

    # check whether all jobs have the same token
    my $job_token;
    my $job_data = $job_info->{data};
    for my $job_id (keys %$job_data) {
        my $data = $job_data->{$job_id};
        is(ref(my $settings = $data->{settings}), 'HASH', "job $job_id has settings");
        is($settings->{JOBTOKEN}, $job_token //= $settings->{JOBTOKEN}, "job $job_id has same job token");
    }
    ok($job_token, 'job token present');
};

# prevent writing to a log file to enable use of combined_like in the following tests
my $usual_log = $t->app->log;
$t->app->log(Mojo::Log->new(level => 'debug'));

subtest 'cycle in directly chained dependencies is handled' => sub {
    my $scheduler = OpenQA::Scheduler::Model::Jobs->singleton;
    my $scheduled_jobs = $scheduler->scheduled_jobs;
    my @directly_chained = (dependency => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED);
    my $dependencies = $schema->resultset('JobDependencies');
    $dependencies->create({child_job_id => 99928, parent_job_id => 99927, @directly_chained});
    $dependencies->create({child_job_id => 99927, parent_job_id => 99928, @directly_chained});
    $scheduler->_update_scheduled_jobs;
    is($scheduled_jobs->{99927}->{priority}, 45, 'regular prio for job 99927 assumed');
    is($scheduled_jobs->{99928}->{priority}, 46, 'regular prio for job 99928 assumed');
    is($scheduled_jobs->{$_}->{priority_offset}, 0, "job $_ not deprioritized yet") for (99927, 99928);
    combined_like { $scheduler->schedule }
    qr/Unable to serialize directly chained job sequence of 9992(7|8): detected cycle at 9992(7|8)/,
      'info about cycle logged';
    $scheduler->_update_scheduled_jobs;    # apply deprioritization
    is($scheduled_jobs->{99927}->{priority}, 46, 'reduced prio for job 99927 assumed');
    is($scheduled_jobs->{99928}->{priority}, 47, 'reduced prio for job 99928 assumed');
    is($scheduled_jobs->{$_}->{priority_offset}, -1, "job $_ is deprioritized") for (99927, 99928);
};

# restore usual logging
$t->app->log($usual_log);

# remove unwanted fixtures
$jobs->search({id => [99927, 99928]})->delete;

# create dependency tree and schedule the jobs
# note: using exclusively parallel dependencies, see graph below where children are right to their parents
#   D
#  / \
# A   \
# B    E
#  \  /
#   C-
#     \
#      F
my $jobA = _job_create('A');
my $jobB = _job_create('B');
my $jobC = _job_create('C', [$jobB->id]);
my $jobD = _job_create('D', [$jobA->id]);
my $jobE = _job_create('E', $jobC->id . ',' . $jobD->id);    # test also IDs passed as comma separated string
my $jobF = _job_create('F', [$jobC->id]);
$jobA->set_prio(3);
$jobB->set_prio(2);
$jobC->set_prio(4);
$_->set_prio(1) for ($jobD, $jobE, $jobF);
_schedule();
$_->discard_changes for ($jobA, $jobB, $jobC, $jobD, $jobE, $jobF);

subtest 'vlan setting' => sub {
    my @jobs_in_expected_order = (
        $jobB => 'lowest prio of jobs without parents',
        $jobC => 'direct child of B',
        $jobF => 'direct child of C',
        $jobA => 'E is direct child of C, but A and D must be started first. A was picked',
        $jobD => 'direct child of A. D is picked',
        $jobE => 'C and D are now running so we can start E. E is picked',
    );
    for my $i (0 .. 5) {
        my $job = $sent->{job}->{$jobs_in_expected_order[$i * 2]->id}->{job};
        ok(defined $job, $jobs_in_expected_order[$i * 2 + 1]) or die;
        is($sent->{job}->{$jobs_in_expected_order[$i * 2]->id}->{jobhash}->{settings}->{NICVLAN},
            1, 'same vlan for whole group');
    }
};

my %exp_cluster_jobs = (
    $jobA->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [$jobD->id],
        parallel_parents => [],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 1,
        ok => 0,
        state => RUNNING,
    },
    $jobB->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [$jobC->id],
        parallel_parents => [],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 1,
        ok => 0,
        state => RUNNING,
    },
    $jobC->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [$jobE->id, $jobF->id],
        parallel_parents => [$jobB->id],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 0,
        ok => 0,
        state => RUNNING,
    },
    $jobD->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [$jobE->id],
        parallel_parents => [$jobA->id],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 0,
        ok => 0,
        state => RUNNING,
    },
    $jobE->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [],
        parallel_parents => [$jobC->id, $jobD->id],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 0,
        ok => 0,
        state => RUNNING,
    },
    $jobF->id => {
        chained_children => [],
        chained_parents => [],
        parallel_children => [],
        parallel_parents => [$jobC->id],
        directly_chained_children => [],
        directly_chained_parents => [],
        is_parent_or_initial_job => 0,
        ok => 0,
        state => RUNNING,
    },
);
sub exp_cluster_jobs_for {
    my ($job) = @_;

    # note: The actual dependency info is the same for every job within the cluster.
    #       The only difference is the 'is_parent_or_initial_job' flag (which is used
    #       to implement the 'skip_ok_result_children' parameter).

    # C is only a child when starting from B
    $exp_cluster_jobs{$jobC->id}{is_parent_or_initial_job} = ($job ne 'B') ? 1 : 0;
    # D is only a child when starting from A
    $exp_cluster_jobs{$jobD->id}{is_parent_or_initial_job} = ($job ne 'A') ? 1 : 0;
    # E and F are always children except when starting from them
    $exp_cluster_jobs{$jobE->id}{is_parent_or_initial_job} = ($job eq 'E') ? 1 : 0;
    $exp_cluster_jobs{$jobF->id}{is_parent_or_initial_job} = ($job eq 'F') ? 1 : 0;
    return \%exp_cluster_jobs;
}
sub log_job_info {
    my %jobs = (A => $jobA, B => $jobB, C => $jobC, D => $jobD, E => $jobE, F => $jobF);    # uncoverable statement
    note 'job IDs:';    # uncoverable statement
    note "job $_: " . $jobs{$_}->id for sort keys %jobs;    # uncoverable statement
}
subtest 'cluster info' => sub {
    is_deeply($jobA->cluster_jobs, exp_cluster_jobs_for 'A', 'cluster info for job A');
    is($jobA->blocked_by_id, undef, 'job A is unblocked');
    is_deeply($jobB->cluster_jobs, exp_cluster_jobs_for 'B', 'cluster info for job B');
    is($jobB->blocked_by_id, undef, 'job B is unblocked');
    is_deeply($jobC->cluster_jobs, exp_cluster_jobs_for 'C', 'cluster info for job C');
    is($jobC->blocked_by_id, undef, 'job C is unblocked');
    is_deeply($jobD->cluster_jobs, exp_cluster_jobs_for 'D', 'cluster info for job D');
    is($jobD->blocked_by_id, undef, 'job D is unblocked');
    is_deeply($jobE->cluster_jobs, exp_cluster_jobs_for 'E', 'cluster info for job E');
    is($jobE->blocked_by_id, undef, 'job E is unblocked');
    is_deeply($jobF->cluster_jobs, exp_cluster_jobs_for 'F', 'cluster info for job F');
    is($jobF->blocked_by_id, undef, 'job F is unblocked');
} or log_job_info;

subtest 'failed parallel parent causes parallel children to fails as PARALLEL_FAILED' => sub {
    is($jobA->done(result => FAILED), FAILED, 'parallel parent A set to failed');
    # reload changes from DB - parallel children should be cancelled by failed jobA
    $_->discard_changes for ($jobD, $jobE);
    # this should not change the result which is parallel_failed due to failed jobA
    is($jobD->done(result => INCOMPLETE), INCOMPLETE, 'parallel child D set to incomplete');
    is($jobE->done(result => INCOMPLETE), INCOMPLETE, 'parallel child E set to incomplete');

    my $job = _job_deps($jobA->id);
    is($job->{state}, DONE, 'job_set_done changed state');
    is($job->{result}, FAILED, 'job_set_done changed result');
    $job = _job_deps($jobB->id);
    is($job->{state}, RUNNING, 'job_set_done changed state');
    $job = _job_deps($jobC->id);
    is($job->{state}, RUNNING, 'job_set_done changed state');
    $job = _job_deps($jobD->id);
    is($job->{state}, DONE, 'job_set_done changed state');
    is($job->{result}, PARALLEL_FAILED, 'job_set_done changed result, jobD failed because of jobA');
    $job = _job_deps($jobE->id);
    is($job->{state}, DONE, 'job_set_done changed state');
    is($job->{result}, PARALLEL_FAILED, 'job_set_done changed result, jobE failed because of jobD');
    $jobF->discard_changes;
    $job = _job_deps($jobF->id);
    is($job->{state}, RUNNING, 'job_set_done changed state');
};

sub _check_mm_api {
    my $explain_tx_res = sub {
        diag explain $t->tx->res->content;    # uncoverable statement
    };
    $t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id])->or($explain_tx_res);
    $t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => [])->or($explain_tx_res);
    $t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id])->or($explain_tx_res);
}
subtest 'MM API for children status - available only for running jobs' => sub {
    isnt(my $job_token = $sent->{job}->{$jobC->id}->{worker}->get_property('JOBTOKEN'), undef, 'JOBTOKEN is present');
    $t->ua->on(start => sub { my ($ua, $tx) = @_; $tx->req->headers->add('X-API-JobToken' => $job_token) });
    _check_mm_api;
};

subtest 'clone and schedule parallel cluster' => sub {
    ok(defined $jobF->auto_duplicate, 'duplicating parallel child works');

    my $job = _job_deps($jobA->id);    # cloned
    is($job->{state}, DONE, 'no change');
    is($job->{result}, FAILED, 'no change');
    ok(defined $job->{clone_id}, 'cloned');
    my $jobA2 = $job->{clone_id};

    $job = _job_deps($jobB->id);    # cloned
    is($job->{result}, PARALLEL_FAILED, "$job->{id} B stopped");
    ok(defined $job->{clone_id}, 'cloned');
    my $jobB2 = $job->{clone_id};

    $job = _job_deps($jobC->id);    # cloned
    is($job->{state}, RUNNING, 'no change');
    is($job->{result}, PARALLEL_FAILED, 'C is restarted');
    ok(defined $job->{clone_id}, 'cloned');
    my $jobC2 = $job->{clone_id};

    $job = _job_deps($jobD->id);    # cloned
    is($job->{state}, DONE, 'no change');
    is($job->{result}, PARALLEL_FAILED, 'no change');
    ok(defined $job->{clone_id}, 'cloned');
    my $jobD2 = $job->{clone_id};

    $job = _job_deps($jobE->id);    # cloned
    is($job->{state}, DONE, 'no change');
    is($job->{result}, PARALLEL_FAILED, 'no change');
    ok(defined $job->{clone_id}, 'cloned');
    my $jobE2 = $job->{clone_id};

    $job = _job_deps($jobF->id);    # cloned
    is($job->{state}, RUNNING, 'no change');
    ok(defined $job->{clone_id}, 'cloned');
    my $jobF2 = $job->{clone_id};

    $job = _job_deps($jobA2);
    is($job->{state}, SCHEDULED, 'no change');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply($job->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, 'cloned deps');

    $job = _job_deps($jobB2);
    is($job->{state}, SCHEDULED, 'cloned jobs are scheduled');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply($job->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, 'cloned deps');

    $job = _job_deps($jobC2);
    is($job->{state}, SCHEDULED, 'cloned jobs are scheduled');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply($job->{parents}, {Parallel => [$jobB2], Chained => [], 'Directly chained' => []}, 'cloned deps');

    $job = _job_deps($jobD2);
    is($job->{state}, SCHEDULED, 'no change');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply($job->{parents}, {Parallel => [$jobA2], Chained => [], 'Directly chained' => []}, 'cloned deps');

    $job = _job_deps($jobE2);
    is($job->{state}, SCHEDULED, 'no change');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply([sort @{$job->{parents}->{Parallel}}], [sort ($jobC2, $jobD2)], 'cloned deps');

    $job = _job_deps($jobF2);
    is($job->{state}, SCHEDULED, 'cloned jobs are scheduled');
    is($job->{clone_id}, undef, 'no clones');
    is_deeply($job->{parents}, {Parallel => [$jobC2], Chained => [], 'Directly chained' => []}, 'cloned deps');

    subtest 'cloning does not change MM API' => \&_check_mm_api;

    # now we have:
    # A <--- D <--- E
    # done   done   done
    #              /
    # B <--- C <--/
    # run    run
    #        ^
    #        \--- F
    #             run
    #
    # A2 <--- D2 <--- E2
    # sch     sch     sch
    #                /
    #           v---/
    # B2 <--- C2 <--- F2
    # sch     sch     sch

    # Now the cloned group should be scheduled. We already called job_set_done on jobE, so worker 6 is available.

    # We have 3 free workers (as B,C and F are still running)
    # and the cluster is 6, so we expect nothing to be SCHEDULED
    _schedule();
    is(_job_deps($jobA2)->{state}, SCHEDULED, 'job still scheduled');

    # now free two of them and create one more worker. So that we
    # have 6 free, but have vlan 1 still busy
    $_->done(result => PASSED) for ($jobC, $jobF);
    $c->_register($schema, 'host', "10", \%workercaps);
    _schedule();

    ok(exists $sent->{job}->{$jobA2}, " $jobA2 was assigned") or die "A2 $jobA2 wasn't scheduled";
    $job = $sent->{job}->{$jobA2}->{jobhash};
    is($job->{id}, $jobA2, "jobA2");    # lowest prio of jobs without parents
    is($job->{settings}->{NICVLAN}, 2, "different vlan") or die explain $job;

    ok(exists $sent->{job}->{$jobB2}, " $jobB2 was assigned") or die "B2 $jobB2 wasn't scheduled";
    $job = $sent->{job}->{$jobB2}->{job}->to_hash;
    is($job->{id}, $jobB2, "jobB2");    # lowest prio of jobs without parents

    is($job->{settings}->{NICVLAN}, 2, "different vlan") or die explain $job;

    $jobB->done(result => PASSED);
    $jobs->find($_)->done(result => PASSED) for ($jobA2, $jobB2, $jobC2, $jobD2, $jobE2, $jobF2);
};

subtest 're-use vlan' => sub {
    $jobA = _job_create('A');
    $jobB = _job_create('B');
    $jobC = _job_create('C', [$jobB->id]);
    $jobD = _job_create('D', [$jobA->id]);
    $jobE = _job_create('E', $jobC->id . ',' . $jobD->id);    # test also IDs passed as comma separated string
    $jobF = _job_create('F', [$jobC->id]);
    is($_->blocked_by_id, undef, $_->TEST . ' is unblocked') for ($jobA, $jobB, $jobC, $jobD, $jobE, $jobF);
    $c->_register($schema, 'host', $_, \%workercaps) for (qw(15 16 17 18));
    _schedule();
    my $job = $sent->{job}->{$jobD->id}->{job}->to_hash;    # all vlans are free so we take the first
    is($job->{settings}->{NICVLAN}, 1, 'reused vlan') or die explain $job;
};

subtest 'simple chained dependency cloning' => sub {
    my $jobX = _job_create('X');
    my $jobY = _job_create('Y', undef, [$jobX->id]);
    is($jobX->done(result => PASSED), PASSED, 'jobX set to done');
    $jobX->discard_changes;

    # current state:
    # X <---- Y
    # done    sch.
    is_deeply(
        $jobY->to_hash(deps => 1)->{parents},
        {Chained => [$jobX->id], Parallel => [], 'Directly chained' => []},
        'parents of jobY'
    );

    # when Y is scheduled and X is duplicated, Y must be cancelled and Y2 needs to depend on X2
    my $jobX2 = $jobX->auto_duplicate;
    $jobY->discard_changes;
    is($jobY->state, CANCELLED, 'jobY was cancelled');
    is($jobY->result, PARALLEL_RESTARTED, 'jobY was skipped');
    my $jobY2 = $jobY->clone;
    ok(defined $jobY2, "jobY was cloned too");
    is($jobY2->blocked_by_id, $jobX2->id, "JobY2 is blocked");
    is_deeply(
        $jobY2->to_hash(deps => 1)->{parents},
        {Chained => [$jobX2->id], Parallel => [], 'Directly chained' => []},
        "JobY parents fit"
    );
    is($jobX2->id, $jobY2->parents->single->parent_job_id, 'jobY2 parent is now jobX clone');
    is($jobX2->clone, undef, 'no clone');
    is($jobY2->clone, undef, 'no clone');

    # current state:
    # X
    # done
    #
    # X2 <---- Y
    # sch.    sch.
    ok($jobX2->done(result => 'passed'), 'jobX2 set to done');
    ok($jobY2->done(result => 'passed'), 'jobY set to done');

    # current state:
    # X <---- Y
    # done    skipped
    #
    # X2 <---- Y2
    # done    done
    ok($jobY2->done(result => 'passed'), 'jobY2 set to done');

    # current state:
    # X
    # done
    #
    #       /-- Y done
    #    <-/
    # X2 <---- Y2
    # done    done
    my $jobX3 = $jobX2->auto_duplicate;

    # current state:
    # X
    # done
    #
    #       /-- Y done
    #    <-/
    # X2 <---- Y2
    # done    done
    #
    # X3 <---- Y3
    # sch.    sch.
    $jobY2->discard_changes;
    isnt($jobY2->clone_id, undef, 'child job Y2 has been cloned together with parent X2');

    my $jobY3_id = $jobY2->clone_id;
    my $jobY3 = _job_deps($jobY3_id);
    is($jobY2->clone->blocked_by_id, $jobX3->id, 'jobY3 blocked');
    is_deeply(
        $jobY3->{parents},
        {Chained => [$jobX3->id], Parallel => [], 'Directly chained' => []},
        'jobY3 parent is now jobX3'
    );
};

subtest 'duplicate parallel siblings' => sub {
    # checking siblings scenario
    # original state, all job set as running
    # H <-(parallel) J
    # ^             ^
    # | (parallel)  | (parallel)
    # K             L
    my $jobH = _job_create('H');
    my $jobK = _job_create('K', [$jobH->id]);
    my $jobJ = _job_create('J', [$jobH->id]);
    my $jobL = _job_create('L', [$jobJ->id]);

    # hack jobs to appear running to scheduler
    _jobs_update_state([$jobH, $jobJ, $jobK, $jobL], RUNNING);

    # expected output after cloning D, all jobs scheduled
    # H2 <-(parallel) J2
    # ^              ^
    # | (parallel)   | (parallel)
    # K2             L2

    my $jobL2 = $jobL->auto_duplicate;
    ok($jobL2, 'jobL duplicated');
    # reload data from DB
    $_->discard_changes for ($jobH, $jobK, $jobJ, $jobL);
    # check other clones
    ok($_->clone, 'job ' . $_->TEST . ' cloned') for ($jobJ, $jobH, $jobK);

    my $jobJ2 = $jobL2->to_hash(deps => 1)->{parents}->{Parallel}->[0];
    is($jobJ2, $jobJ->clone->id, 'J2 cloned with parallel parent dep');
    my $jobH2 = _job_deps($jobJ2)->{parents}->{Parallel}->[0];
    is($jobH2, $jobH->clone->id, 'H2 cloned with parallel parent dep');
    is_deeply(
        _job_deps($jobH2)->{children}->{Parallel},
        [$jobK->clone->id, $jobJ2],
        'K2 cloned with parallel children dep'
    );
};

subtest 'duplicate parallel parent in tree with all dependency types' => sub {
    # checking all-in mixed scenario
    # create original state (excluding TA which is the same as T just directly chained to Q):
    # Q <- (chained) W <-\ (parallel)
    #   ^- (chained) U <-- (parallel) T
    #   ^- (chained) R <-/ (parallel) | (chained)
    #   ^-----------------------------/
    # note: Q is done; W,U,R, T and TA are running
    my $jobQ = _job_create('Q');
    my $jobW = _job_create('W', undef, [$jobQ->id]);
    my $jobU = _job_create('U', undef, [$jobQ->id]);
    my $jobR = _job_create('R', undef, [$jobQ->id]);
    my $jobT = _job_create('T', [$jobW->id, $jobU->id, $jobR->id], [$jobQ->id]);
    my $jobTA = _job_create('TA', [$jobW->id, $jobU->id, $jobR->id], undef, [$jobQ->id]);

    # check dependencies of job Q
    my $jobQ_deps = _job_deps($jobQ->id);
    my @sorted_got = sort(@{$jobQ_deps->{children}->{Chained}});
    my @sorted_exp = sort(($jobW->id, $jobU->id, $jobR->id, $jobT->id));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is chained parent to all jobs except jobTA')
      or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobQ_deps->{children}->{'Directly chained'}});
    @sorted_exp = sort(($jobTA->id));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is directly chained parent to jobTA') or diag explain \@sorted_got;
    is($jobT->blocked_by_id, $jobQ->id, 'JobT is blocked by job supposed to run before');
    is($jobTA->blocked_by_id, $jobQ->id, 'JobT2 is blocked by job supposed to run *directly* before');
    is($jobW->blocked_by_id, $jobQ->id, 'JobW is blocked by job supposed to run before');

    # note: Maybe the blocked_by behavior for jobs to run *directly* after each other needs to be changed
    #       later. Nevertheless, let's explicitly assert this behavior so we know what we have right now.

    # hack jobs to appear to scheduler in desired state
    _jobs_update_state([$jobQ], DONE);
    _jobs_update_state([$jobW, $jobU, $jobR, $jobT, $jobTA], RUNNING);

    # duplicate job U
    my $jobU2 = $jobU->auto_duplicate;
    ok($jobU2, 'jobU duplicated');

    # reload data from DB
    $_->discard_changes for ($jobQ, $jobW, $jobU, $jobR, $jobT, $jobTA);

    # check whether jobs have been cloned
    # expected state (excluding TA2 which is the same as T2 just directly chained to Q2):
    # Q2 <- (chained) W2 <-\ (parallel)
    #    ^- (chained) E2 <-- (parallel) T2
    #    ^- (chained) R2 <-/ (parallel) | (chained)
    #    ^------------------------------/
    # note 1: Q is still done; Q2, W2, E2, R2, T2 and TA2 are scheduled
    # note 2: jobQ has been cloned because it is the direct parent of jobTA which is cloned
    #         because it is part of the parallel cluster of jobU. So jobQ would not have been cloned
    #         without jobTA.
    ok($jobU->clone_id, 'jobU cloned (the job we call auto_duplicate on');
    ok($jobW->clone_id, 'jobW cloned (part of parallel cluster of jobU)');
    ok($jobR->clone_id, 'jobR cloned (part of parallel cluster of jobU)');
    ok($jobT->clone_id, 'jobT cloned (part of parallel cluster of jobU)');
    ok($jobTA->clone_id, 'jobTA cloned (part of parallel cluster of jobU)');
    ok($jobQ->clone_id, 'jobQ cloned (direct parent of jobTA)');

    # check certain job states
    is($jobU->state, RUNNING,
        'original job state not altered (expected to be set to USER_RESTARTED after auto_duplicate is called)');
    is($jobQ->state, DONE, 'state of original parent jobQ is unaffected');
    is($_->result, PARALLEL_RESTARTED, 'parallel jobs are considered PARALLEL_RESTARTED')
      for ($jobW, $jobR, $jobT, $jobTA);

    # determine dependencies of existing and cloned jobs for further checks
    # note 3: The variables of cloned jobs have a "2" suffix here. So jobQ2 is the clone of jobQ.
    my $jobQ2 = _job_deps($jobQ->clone_id);
    my $jobW2 = _job_deps($jobW->clone_id);
    my $jobR2 = _job_deps($jobR->clone_id);
    my $jobT2 = _job_deps($jobT->clone_id);
    my $jobTA2 = _job_deps($jobTA->clone_id);
    $jobQ = _job_deps($jobQ->id);
    $jobTA = _job_deps($jobTA->id);

    # check chained children
    # note 4: As stated in note 2, jobQ2 has only been cloded due to its dependency with jobTA. However,
    #         the other jobs are still supposed to be associated with the clone jobQ2 instead of the original
    #         job so all cloned jobs are consistently part of the new dependency tree.
    @sorted_got = sort(@{$jobQ->{children}->{Chained}});
    @sorted_exp = sort(($jobW->id, $jobU->id, $jobR->id, $jobT->id));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is still chained parent to all original jobs')
      or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobQ2->{children}->{Chained}});
    @sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}, $jobT2->{id}));
    is_deeply(\@sorted_got, \@sorted_exp,
        'jobQ2 is chained parent to all cloned jobs (except jobTA2 which is directly chained)')
      or diag explain \@sorted_got;

    # check directly chained children
    @sorted_got = sort(@{$jobQ->{children}->{'Directly chained'}});
    @sorted_exp = sort(($jobTA->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is still the only directly chained parent to jobTA')
      or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobQ2->{children}->{'Directly chained'}});
    @sorted_exp = sort(($jobTA2->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobQ2 is directly chained parent to clone jobTA2')
      or diag explain \@sorted_got;

    # check chained parents
    @sorted_got = sort(@{$jobTA2->{parents}->{'Chained'}});
    @sorted_exp = sort(());
    is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 not regularly chained after jobQ') or diag explain \@sorted_got;

    # check directly chained parents
    @sorted_got = sort(@{$jobTA2->{parents}->{'Directly chained'}});
    @sorted_exp = sort(($jobQ2->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 directly chained after jobQ') or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobTA->{parents}->{'Directly chained'}});
    @sorted_exp = sort(($jobQ->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobTA is still directly chained after jobQ') or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobTA2->{parents}->{'Directly chained'}});
    @sorted_exp = sort(($jobQ2->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 directly chained after clone jobQ2') or diag explain \@sorted_got;

    # check parallel parents
    @sorted_got = sort(@{$jobT2->{parents}->{Parallel}});
    @sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}));
    is_deeply(\@sorted_got, \@sorted_exp, 'jobT is parallel child of all jobs except jobQ')
      or diag explain \@sorted_got;
    @sorted_got = sort(@{$jobTA2->{parents}->{Parallel}});
    is_deeply(\@sorted_got, \@sorted_exp, 'jobTA is parallel child of all jobs except jobQ')
      or diag explain \@sorted_got;

    # check children of "parallel parents"
    is_deeply(
        $jobW2->{children},
        {Chained => [], Parallel => [$jobT2->{id}, $jobTA2->{id}], 'Directly chained' => []},
        'jobW2 has no child dependency to sibling'
    ) or diag explain $jobW2->{children};
    is_deeply(
        $jobU2->to_hash(deps => 1)->{children},
        {Chained => [], Parallel => [$jobT2->{id}, $jobTA2->{id}], 'Directly chained' => []},
        'jobU2 has no child dependency to sibling'
    ) or diag explain $jobU2->to_hash(deps => 1)->{children};
    is_deeply(
        $jobR2->{children},
        {Chained => [], Parallel => [$jobT2->{id}, $jobTA2->{id}], 'Directly chained' => []},
        'jobR2 has no child dependency to sibling'
    ) or diag explain $jobR2->{children};

    # check parents of "parallel parents"
    is_deeply(
        $jobW2->{parents},
        {Chained => [$jobQ2->{id}], Parallel => [], 'Directly chained' => []},
'jobW2 has clone of jobQ as chained parent (although jobQ has only been cloned because it is a direct parent of jobTA)'
    ) or diag explain $jobW2->{parents};
    is_deeply(
        $jobU2->to_hash(deps => 1)->{parents},
        {Chained => [$jobQ2->{id}], Parallel => [], 'Directly chained' => []},
'jobU2 has clone of jobQ as chained parent (although jobQ has only been cloned because it is a direct parent of jobTA)'
    ) or diag explain $jobU2->to_hash(deps => 1)->{parents};
    is_deeply(
        $jobR2->{parents},
        {Chained => [$jobQ2->{id}], Parallel => [], 'Directly chained' => []},
'jobR2 has clone of jobQ as chained parent (although jobQ has only been cloned because it is a direct parent of jobTA)'
    ) or diag explain $jobR2->{parents};
};

subtest 'clonging of clones' => sub {
    # note: This is to check whether duplication properly traverses clones to find latest clone. The test is divided
    #       into two parts, cloning jobO and then jobI.
    # original state, all jobs DONE:
    # P <-(parallel) O <-(parallel) I
    my $jobP = _job_create('P');
    my $jobO = _job_create('O', [$jobP->id]);
    my $jobI = _job_create('I', [$jobO->id]);

    # hack jobs to appear to scheduler in desired state
    _jobs_update_state([$jobP, $jobO, $jobI], DONE);

    # cloning O gets to expected state:
    # P2 <-(parallel) O2 (clone of) O <-(parallel) I2
    my $jobO2 = $jobO->auto_duplicate;
    ok($jobO2, 'jobO duplicated');
    # reload data from DB
    $_->discard_changes for ($jobP, $jobO, $jobI);
    # check other clones
    ok($jobP->clone, 'jobP cloned');
    ok($jobO->clone, 'jobO cloned');
    ok($jobI->clone, 'jobI cloned');

    $jobO2 = _job_deps($jobO2->id);
    $jobI = _job_deps($jobI->id);
    my $jobI2 = _job_deps($jobI->{clone_id});
    my $jobP2 = _job_deps($jobP->clone->id);

    is_deeply($jobI->{parents}->{Parallel}, [$jobO->id], 'jobI retain its original parent');
    is_deeply($jobI2->{parents}->{Parallel}, [$jobO2->{id}], 'jobI2 got new parent');
    is_deeply($jobO2->{parents}->{Parallel}, [$jobP2->{id}], 'clone jobO2 gets new parent jobP2');

    # get Jobs RS from ids for cloned jobs
    $jobO2 = $jobs->find($jobO2->{id});
    $jobP2 = $jobs->find($jobP2->{id});
    $jobI2 = $jobs->find($jobI2->{id});
    # set P2 running and O2 done
    _jobs_update_state([$jobP2], RUNNING);
    _jobs_update_state([$jobO2], DONE);
    _jobs_update_state([$jobI2], DONE);

    # cloning I gets to expected state:
    # P3 <-(parallel) O3 <-(parallel) I2

    # let's call this one I2'
    $jobI2 = $jobI2->auto_duplicate;
    ok($jobI2, 'jobI2 duplicated');

    # reload data from DB
    $_->discard_changes for ($jobP2, $jobO2);

    ok($jobP2->clone, 'jobP2 cloned');
    ok($jobO2->clone, 'jobO2 cloned');

    $jobI2 = _job_deps($jobI2->id);
    my $jobO3 = _job_deps($jobO2->clone->id);
    my $jobP3 = _job_deps($jobP2->clone->id);

    is_deeply($jobI2->{parents}->{Parallel}, [$jobO3->{id}], 'jobI2 got new parent jobO3');
    is_deeply($jobO3->{parents}->{Parallel}, [$jobP3->{id}], 'clone jobO3 gets new parent jobP3');
};

subtest 'clone chained child with siblings; then clone chained parent' =>
  sub {    # see https://progress.opensuse.org/issues/10456
    $jobA = _job_create('116539');
    $jobB = _job_create('116569', undef, [$jobA->id]);
    $jobC = _job_create('116570', undef, [$jobA->id]);
    $jobD = _job_create('116571', undef, [$jobA->id]);

    # hack jobs to appear done to scheduler
    _jobs_update_state([$jobA, $jobB, $jobC, $jobD], DONE, PASSED);

    # only job B failed as incomplete
    $jobB->result(INCOMPLETE);
    $jobB->update;

    # situation, all chained and done, B is incomplete:
    # A <- B
    #   |- C
    #   \- D

    # B failed, auto clone it
    my $jobBc = $jobB->auto_duplicate({dup_type_auto => 1});
    ok($jobBc, 'jobB duplicated');

    # update local copy from DB
    $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

    # expected situation:
    # A <- B' (clone of B)
    #   |- C
    #   \- D
    my $jobBc_h = _job_deps($jobBc->id);
    is_deeply($jobBc_h->{parents}->{Chained}, [$jobA->id], 'jobBc has jobA as chained parent');
    is($jobBc_h->{settings}{TEST}, $jobB->TEST, 'jobBc test and jobB test are equal');

    ok(!$jobC->clone, 'jobC was not cloned');
    my $jobC_h = _job_deps($jobC->id);
    is_deeply($jobC_h->{parents}->{Chained}, [$jobA->id], 'jobC has jobA as chained parent');
    is($jobC_h->{settings}{TEST}, $jobC->TEST, 'jobBc test and jobB test are equal');

    ok(!$jobD->clone, 'jobD was not cloned');
    my $jobD_h = _job_deps($jobD->id);
    is_deeply($jobD_h->{parents}->{Chained}, [$jobA->id], 'jobD has jobA as chained parent');
    is($jobD_h->{settings}{TEST}, $jobD->TEST, 'jobBc test and jobB test are equal');

    # hack jobs to appear running to scheduler
    $jobB->clone->state(RUNNING);
    $jobB->clone->update;

    # clone A
    $jobA->discard_changes;
    ok(!$jobA->clone, "jobA not yet cloned");
    my $jobA2 = $jobA->auto_duplicate;
    ok($jobA2, 'jobA duplicated');
    $jobA->discard_changes;

    $jobA->clone->state(RUNNING);
    $jobA->clone->update;
    $jobA2 = $jobA->clone->auto_duplicate;
    ok($jobA2, 'jobA->clone duplicated');

    # update local copy from DB
    $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

    # expected situation, all chained:
    # A2 <- B2 (clone of Bc)
    #    |- C2
    #    \- D2
    ok($jobB->clone->clone, 'jobB clone jobBd was cloned');
    my $jobB2_h = _job_deps($jobB->clone->clone->clone->id);
    is_deeply($jobB2_h->{parents}->{Chained}, [$jobA2->id], 'jobB2 has jobA2 as chained parent');
    is($jobB2_h->{settings}{TEST}, $jobB->TEST, 'jobB2 test and jobB test are equal');

    ok($jobC->clone, 'jobC was cloned');
    my $jobC2_h = _job_deps($jobC->clone->clone->id);
    is_deeply($jobC2_h->{parents}->{Chained}, [$jobA2->id], 'jobC2 has jobA2 as chained parent');
    is($jobC2_h->{settings}{TEST}, $jobC->TEST, 'jobC2 test and jobC test are equal');

    ok($jobD->clone, 'jobD was cloned');
    my $jobD2_h = _job_deps($jobD->clone->clone->id);
    is_deeply($jobD2_h->{parents}->{Chained}, [$jobA2->id], 'jobD2 has jobA2 as chained parent');
    is($jobD2_h->{settings}{TEST}, $jobD->TEST, 'jobD2 test and jobD test are equal');

    my $jobA2_h = _job_deps($jobA2->id);

    # We are sorting here because is_deeply needs the elements to be with the same order
    # and the DB query doesn't enforce any order
    my @clone_deps = sort { $a <=> $b } @{$jobA2_h->{children}->{Chained}};
    my @deps = sort { $a <=> $b } ($jobB2_h->{id}, $jobC2_h->{id}, $jobD2_h->{id});
    is_deeply(\@clone_deps, \@deps, 'jobA2 has jobB2, jobC2 and jobD2 as children');
  };

subtest 'clone chained parent while children are running' => sub {
    # situation parent is done, children running -> parent is cloned -> parent is running -> parent is cloned. Check all
    # children has new parent:
    # A <- B
    #   |- C
    #   \- D
    $jobA = _job_create('116539A');
    $jobB = _job_create('116569A', undef, [$jobA->id]);
    $jobC = _job_create('116570A', undef, [$jobA->id]);
    $jobD = _job_create('116571A', undef, [$jobA->id]);

    # hack jobs to appear done to scheduler
    _jobs_update_state([$jobA], DONE, PASSED);
    _jobs_update_state([$jobB, $jobC, $jobD], RUNNING);

    my $jobA2 = $jobA->auto_duplicate;
    $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);
    # check all children were cloned and has $jobA as parent
    for ($jobB, $jobC, $jobD) {
        ok($_->clone, 'job cloned');
        my $h = _job_deps($_->clone->id);
        is_deeply($h->{parents}{Chained}, [$jobA2->id], 'job has jobA2 as parent');
    }

    # set jobA2 as running and clone it
    $jobA2 = $jobA->clone;
    is($jobA2->id, $jobA2->id, 'jobA2 is indeed jobA clone');
    $jobA2->state(RUNNING);
    $jobA2->update;
    my $jobA3 = $jobA2->auto_duplicate;
    ok($jobA3, "cloned A2");
    $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

    # check all children were cloned anymore and has $jobA3 as parent
    for ($jobB, $jobC, $jobD) {
        ok($_->clone->clone, 'job correctly not cloned');
        my $h = _job_deps($_->clone->clone->id);
        is_deeply($h->{parents}{Chained}, [$jobA3->id], 'job has jobA3 as parent');
    }
};

subtest 'clone chained parent with chained sub-tree' => sub {
    # situation: chained parent is done, children are all failed and has parallel dependency to the first sibling
    #    /- C
    #    |  |
    # A <-- B
    #    |  |
    #    \- D
    my $duplicate_test = sub {
        $jobA = _job_create('360-A');
        $jobB = _job_create('360-B', undef, [$jobA->id]);
        $jobC = _job_create('360-C', [$jobB->id], [$jobA->id]);
        $jobD = _job_create('360-D', [$jobB->id], [$jobA->id]);

        # hack jobs to appear done to scheduler
        _jobs_update_state([$jobA], DONE, PASSED);
        _jobs_update_state([$jobB, $jobC, $jobD], DONE, FAILED);

        my $jobA2 = $jobA->auto_duplicate;
        $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

        # check all children were cloned and has $jobA as parent
        for ($jobB, $jobC, $jobD) {
            ok($_->clone, 'job cloned');
            my $h = _job_deps($_->clone->id);
            is_deeply($h->{parents}{Chained}, [$jobA2->id], 'job has jobA2 as parent')
              or explain($h->{parents}{Chained});
        }
        for ($jobC, $jobD) {
            my $h = _job_deps($_->clone->id);
            is_deeply($h->{parents}{Parallel}, [$jobB->clone->id], 'job has jobB2 as parallel parent');
        }
    };

    sub _job_create_set_done {
        my ($settings, $state, @create_args) = @_;
        my $job = _job_create($settings, @create_args);
        # hack jobs to appear done to scheduler
        _jobs_update_state([$job], $state, PASSED);
        return $job;
    }
    sub _job_cloned_and_related {
        my ($jobA, $jobB) = @_;
        ok($jobA->clone, 'jobA has a clone');
        my $jobA_hash = _job_deps($jobA->id);
        my $cloneA_hash = _job_deps($jobA->clone->id);
        ok($jobB->clone, 'jobB has a clone');
        my $cloneB = $jobB->clone->id;
        my $rel;
        for my $r (qw(Chained Parallel)) {
            my $res = grep { $_ eq $jobB->id } @{$jobA_hash->{children}{$r}};
            if ($res) {
                $rel = $r;
                last;
            }
        }
        ok($rel, "jobA is $rel parent of jobB");
        my $res = grep { $_ eq $cloneB } @{$cloneA_hash->{children}{$rel}};
        ok($res, "cloneA is $rel parent of cloneB") or explain(@{$cloneA_hash->{children}{$rel}});
    }

    my $slepos_test_workers = sub {
        my $jobSUS = _job_create_set_done('SupportServer', DONE);
        my $jobAS = _job_create_set_done('AdminServer', DONE, [$jobSUS->id]);
        my $jobIS2 = _job_create_set_done('ImageServer2', DONE, undef, [$jobAS->id]);
        my $jobIS = _job_create_set_done('ImageServer', CANCELLED, [$jobSUS->id], [$jobAS->id]);
        my $jobBS = _job_create_set_done('BranchServer', DONE, [$jobAS->id, $jobSUS->id]);
        my $jobT = _job_create_set_done('Terminal', DONE, [$jobBS->id]);

        # clone terminal
        $jobT->duplicate;
        $_->discard_changes for ($jobSUS, $jobAS, $jobIS, $jobIS2, $jobBS, $jobT);

        # check dependencies of clones
        my @related_jobs = (
            [$jobSUS, $jobAS],
            [$jobSUS, $jobIS],
            [$jobSUS, $jobBS],
            [$jobAS, $jobIS],
            [$jobAS, $jobIS2],
            [$jobAS, $jobBS],
            [$jobBS, $jobT]);
        ok(_job_cloned_and_related($_->[0], $_->[1]), 'job ' . $_->[0]->TEST . ' and job ' . $_->[1]->TEST)
          for @related_jobs;
    };

    # This enforces order in the processing of the nodes, to test PR#1623
    my $unordered_sort = \&OpenQA::Jobs::Constants::search_for;
    my $ordered_sort = sub { $unordered_sort->(@_)->search(undef, {order_by => {-desc => 'id'}}) };

    my %tests = ('duplicate' => $duplicate_test, 'slepos test workers' => $slepos_test_workers);
    foreach my $key (sort keys %tests) {
        my $value = $tests{$key};
        no warnings 'redefine';
        *OpenQA::Jobs::Constants::search_for = $unordered_sort;
        subtest "$key unordered" => $value;
        *OpenQA::Jobs::Constants::search_for = $ordered_sort;
        subtest "$key ordered" => $value;
    }
};

subtest 'blocked-by computation in complicated mix of chained and parallel dependencies (SAP setup)' =>
  sub {    # see https://progress.opensuse.org/issues/52928
    my $jobA = _job_create_set_done('hdd_gnome', DONE);
    my $jobB = _job_create('gnome_netweaver', undef, [$jobA->id]);
    my $jobC = _job_create_set_done('hdd_textmode', DONE);
    my $jobD = _job_create('textmode_netweaver', undef, [$jobC->id, $jobB->id]);
    my $jobE = _job_create('node1');
    my $jobF = _job_create('node2');
    my $jobG = _job_create('supportserver', [$jobE->id, $jobF->id], [$jobD->id, $jobC->id]);
    my $jobH = _job_create('final', undef, [$jobG->id, $jobA->id]);
    is($jobB->blocked_by_parent_job, undef);
    is($jobD->blocked_by_parent_job, $jobB->id);
    is($jobG->blocked_by_parent_job, $jobD->id);
  };

ok $mock_send_called, 'mocked ws_send method has been called';

subtest 'WORKER_CLASS validated when creating directly chained dependencies' => sub {
    $jobA = _job_create({%default_job_settings, TEST => 'chained-A', WORKER_CLASS => 'foo'});
    is($jobA->settings->find({key => 'WORKER_CLASS'})->value, 'foo', 'job A has class foo');
    $jobB = _job_create({%default_job_settings, TEST => 'chained-B', WORKER_CLASS => 'bar'}, undef, [$jobA->id]);
    is($jobB->settings->find({key => 'WORKER_CLASS'})->value,
        'bar', 'job B has different class bar (ok for regularly chained dependencies)');
    $jobC = _job_create({%default_job_settings, TEST => 'chained-C'}, undef, [], [$jobB->id]);
    is($jobC->settings->find({key => 'WORKER_CLASS'})->value, 'bar', 'job C inherits worker class from B');
    throws_ok(
        sub { _job_create({%default_job_settings, TEST => 'chained-D', WORKER_CLASS => 'foo'}, [], [], [$jobC->id]) },
        qr/Specified WORKER_CLASS \(foo\) does not match the one from directly chained parent .* \(bar\)/,
        'creation of job with mismatching worker class prevented'
    );
};

subtest 'skip "ok" children' => sub {
    # create a cluster
    #                -> child-1-passed
    #               /
    # parent-passed --> child-2-passed --> child-2-child-1-failed
    #               \
    #                -> child-3-failed
    my $parent = _job_create('parent-passed');
    my $child_1 = _job_create('child-1-passed', undef, undef, [$parent->id]);
    my $child_2 = _job_create('child-2-passed', undef, undef, [$parent->id]);
    my $child_2_child_1 = _job_create('child-2-child-1-failed', undef, undef, [$child_2->id]);
    my $child_3 = _job_create('child-3-failed', undef, undef, [$parent->id]);
    my @all_jobs = ($parent, $child_1, $child_2, $child_2_child_1, $child_3);
    my $log_jobs = sub { note $_->TEST . ': id=' . $_->id . ', clone_id=' . ($_->clone_id // 'none') for @all_jobs };
    $_->update({state => DONE, result => PASSED}) for ($parent, $child_1, $child_2);
    $_->update({state => DONE, result => FAILED}) for ($child_2_child_1, $child_3);
    $_->discard_changes for @all_jobs;

    # duplicate parent
    $parent->auto_duplicate({skip_ok_result_children => 1});
    $_->discard_changes for @all_jobs;

    my $clone = $parent->clone;
    subtest 'jobs have been cloned/skipped as expected' => sub {
        isnt($clone, undef, 'parent has been cloned because it is the direct job to be restarted');
        is($child_1->clone_id, undef, 'child-1 has not been cloned because it is ok');
        isnt($child_2->clone_id, undef, 'child-2 has been cloned because its child failed');
        isnt($child_2_child_1->clone_id, undef, 'child-2-child-1 has been cloned because it failed');
        isnt($child_3->clone_id, undef, 'child-3 has been cloned because it failed');
    } or $log_jobs->();

    my $new_job_cluster = $clone->cluster_jobs;
    subtest 'dependencies of cloned jobs' => sub {
        my @expected_job_ids = ((map { $_->clone_id } ($parent, $child_2, $child_2_child_1, $child_3)), $child_1->id);
        is(ref $new_job_cluster->{$_}, 'HASH', "new cluster contains job $_") for @expected_job_ids;
        is_deeply(
            [sort @{$new_job_cluster->{$clone->id}{directly_chained_children}}],
            [$child_1->id, $child_2->clone_id, $child_3->clone_id],
            'parent contains all children, including the not restarted one'
        );
        is_deeply(
            [sort @{$new_job_cluster->{$child_1->id}{directly_chained_parents}}],
            [$parent->id, $clone->id],
            'skipped job has nevertheless new parent (besides old one) to appear in the new dependency tree as well'
        );
        is_deeply([sort @{$new_job_cluster->{$child_2_child_1->clone_id}{directly_chained_parents}}],
            [$child_2->clone_id], 'parent for child of child assigned');
        # note: It is not exactly clear whether creating a dependency between the skipped job and the new
        #       parent is the best behavior but let's assert it for now.
    } or $log_jobs->() or diag explain $new_job_cluster;
};

subtest 'siblings of running for cluster' => sub {
    my $schedule = OpenQA::Scheduler::Model::Jobs->singleton;
    $schedule->scheduled_jobs->{99999}->{state} = RUNNING;
    $schedule->scheduled_jobs->{99999}->{cluster_jobs} = {1 => 1, 2 => 1};
    my $mock = Test::MockModule->new('OpenQA::Scheduler::Model::Jobs');
    $mock->redefine(_jobs_in_execution => ($jobs->search({id => 99999})->single));
    my ($allocated_jobs, $allocated_workers) = ({}, {});
    $schedule->_pick_siblings_of_running($allocated_jobs, $allocated_workers);
    ok $allocated_jobs, 'some jobs are allocated';
    ok $allocated_workers, 'jobs are allocated to workers';
};

# conduct further tests with mocked scheduled jobs and free workers
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
my @mocked_free_workers
  = OpenQA::Schema->singleton->resultset('Workers')->search({job_id => undef}, {rows => 3, order_by => 'id'})->all;
is scalar @mocked_free_workers, 3, 'test setup provides 3 free workers';
my $spare_worker = pop @mocked_free_workers;
$mock->redefine(determine_free_workers => sub { \@mocked_free_workers });
$mock->redefine(determine_scheduled_jobs => sub { shift->scheduled_jobs(\%mocked_jobs); \%mocked_jobs });

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'debug'));

subtest 'error cases' => sub {
    my $allocated;

    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/Failed to retrieve jobs \(1\) in the DB, reason: only got 0 jobs/, 'job not present in DB';
    is_deeply $allocated, [], 'no job allocated (1)' or diag explain $allocated;

    my $job = $jobs->create({id => 1, state => ASSIGNED, TEST => $mocked_jobs{1}->{test}});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/1.*no longer scheduled, skipping/, 'skippinng job which is no longer scheduled';
    is_deeply $allocated, [], 'no job allocated (2)' or diag explain $allocated;

    $job->update({state => SCHEDULED, assigned_worker_id => $mocked_free_workers[0]->id});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/Worker already got jobs, skipping/, 'skippinng if worker already has jobs';
    is_deeply $allocated, [], 'no job allocated (2)' or diag explain $allocated;

    $job->update({assigned_worker_id => $spare_worker->id});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule }
    qr/1.*already a worker assigned, skipping/, 'skippinng job which has already worker assigned';
    is_deeply $allocated, [], 'no job allocated (3)' or diag explain $allocated;
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
    my ($allocated, $allocated_workers) = (undef, {});
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule($allocated_workers) }
    qr/Need to schedule 3 parallel jobs for job 1.*Discarding job (1|2|3).*Discarding job (1|2|3)/s,
      'discarding jobs due to incomplete parallel cluster';
    is_deeply $allocated, [], 'no jobs allocated (1)' or diag explain $allocated;
    is $mocked_jobs{1}->{priority_offset}, 10, 'priority of parallel parent increased (once per child)';
    is_deeply $allocated_workers, {}, 'no workers "held" so far while still increased prio'
      or diag explain $allocated_workers;

    # run the scheduler again assuming highest prio for parallel parent; worker supposed to be "held"
    $mocked_jobs{1}->{priority} = 0;
    combined_like { $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule($allocated_workers) }
    qr/Holding worker .* for job (1|2|3) to avoid starvation.*Holding worker .* for job (1|2|3) to avoid starvation/s,
      'holding 2 workers (for 2 of our parallel jobs while 3rd worker is unavailable)';
    is_deeply [sort keys %$allocated_workers], [map { $_->id } @mocked_free_workers], 'both free workers "held"';
    ok $_ >= 1 && $_ <= 3, "worker held for expected job ($_)" for values %$allocated_workers;
};

done_testing();
