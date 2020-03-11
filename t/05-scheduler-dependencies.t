#!/usr/bin/env perl

# Copyright (C) 2014-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use Test::Exception;
use Test::Mojo;
use Test::More;
use Test::Warnings;
use OpenQA::WebSockets::Client;
use OpenQA::Jobs::Constants;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Test::Utils 'embed_server_for_testing';
use Test::MockModule;

subtest 'serialize sequence of directly chained dependencies' => sub {
    my %cluster_info = (
        0 => {
            directly_chained_children => [1, 6, 7, 8, 12],
            directly_chained_parents  => [],
            chained_children          => [13],               # supposed to be ignored
            chained_parents           => [],                 # supposed to be ignored
        },
        1 => {
            directly_chained_children => [2, 4],
            directly_chained_parents  => [0],
        },
        2 => {
            directly_chained_children => [3],
            directly_chained_parents  => [0],
        },
        3 => {
            directly_chained_children => [],
            directly_chained_parents  => [2],
        },
        4 => {
            directly_chained_children => [5],
            directly_chained_parents  => [0],
        },
        5 => {
            directly_chained_children => [],
            directly_chained_parents  => [4],
        },
        6 => {
            directly_chained_children => [],
            directly_chained_parents  => [0],
        },
        7 => {
            directly_chained_children => [],
            directly_chained_parents  => [0],
        },
        8 => {
            directly_chained_children => [9, 10],
            directly_chained_parents  => [0],
        },
        9 => {
            directly_chained_children => [],
            directly_chained_parents  => [8],
        },
        10 => {
            directly_chained_children => [11],
            directly_chained_parents  => [8],
        },
        11 => {
            directly_chained_children => [],
            directly_chained_parents  => [10],
        },
        12 => {
            directly_chained_children => [],
            directly_chained_parents  => [0],
        },
        13 => {
            directly_chained_children => [14],
            directly_chained_parents  => [0],
            chained_children          => [],      # supposed to be ignored
            chained_parents           => [13],    # supposed to be ignored
        },
        14 => {
            directly_chained_children => [],
            directly_chained_parents  => [13],
        },
    );
    # notes: * The array directly_chained_parents is actually not used by the algorithm. From the test perspective
    #          we don't want to rely on that detail, though.
    #        * The direct chain is interrupted between 12 and 13 by a regularily chained dependency. Hence there
    #          are two distinct clusters of directly chained dependencies present.

    my @expected_sequence = (2, 3);
    my ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(2, \%cluster_info);
    is_deeply($computed_sequence, \@expected_sequence, 'sub sequence starting from job 2')
      or diag explain $computed_sequence;
    is_deeply([sort @$visited], [2, 3], 'relevant jobs visited');

    @expected_sequence = (1, [2, 3], [4, 5]);
    ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(1, \%cluster_info);
    is_deeply($computed_sequence, \@expected_sequence, 'sub sequence starting from job 1')
      or diag explain $computed_sequence;
    is_deeply([sort @$visited], [1, 2, 3, 4, 5], 'relevant jobs visited');

    @expected_sequence = (0, [1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12);
    ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info);
    is_deeply($computed_sequence, \@expected_sequence, 'whole sequence starting from job 0')
      or diag explain $computed_sequence;
    is_deeply([sort @$visited], [0, 1, 10, 11, 12, 2, 3, 4, 5, 6, 7, 8, 9], 'relevant jobs visited');

    @expected_sequence = (13, 14);
    ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(13, \%cluster_info);
    is_deeply($computed_sequence, \@expected_sequence, 'whole sequence starting from job 13')
      or diag explain $computed_sequence;
    is_deeply([sort @$visited], [13, 14], 'relevant jobs visited');

    # provide a sort function to control the order between multiple children of the same parent
    my %sort_criteria = (12 => 'anfang', 7 => 'danach', 6 => 'mitte', 8 => 'nach mitte', 1 => 'zuletzt');
    my $sort_function = sub {
        return [sort { ($sort_criteria{$a} // $a) cmp($sort_criteria{$b} // $b) } @{shift()}];
    };
    @expected_sequence = (0, 12, 7, 6, [8, [10, 11], 9], [1, [2, 3], [4, 5]]);
    ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info, $sort_function);
    is_deeply($computed_sequence, \@expected_sequence, 'sorting criteria overrides sorting by ID')
      or diag explain $computed_sequence;

    # introduce a cycle
    push(@{$cluster_info{6}->{directly_chained_children}}, 12);
    throws_ok(
        sub {
            OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info);
        },
        qr/cycle at (6|12)/,
        'compution dies on cycle'
    );
};

my $schema = OpenQA::Test::Database->new->create();

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client      => OpenQA::WebSockets::Client->singleton,
);

my $sent = {};

OpenQA::Scheduler::Model::Jobs->singleton->shuffle_workers(0);
sub schedule {
    my $id = OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    for my $i (@$id) {
        _jobs_update_state([$schema->resultset('Jobs')->find($i->{job})], RUNNING);
    }
}

# Mangle worker websocket send, and record what was sent
my $jobs_result_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my $mock_send_called;
$jobs_result_mock->mock(
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


subtest 'assign multiple jobs to worker' => sub {
    my $worker       = $schema->resultset('Workers')->first;
    my $worker_id    = $worker->id;
    my @job_ids      = (99926, 99927, 99928);
    my @jobs         = $schema->resultset('Jobs')->search({id => {-in => \@job_ids}})->all;
    my @job_sequence = (99927, [99928, 99926]);

    # use fake web socket connection
    my $fake_ws_tx    = OpenQA::Test::FakeWebSocketTransaction->new;
    my $sent_messages = $fake_ws_tx->sent_messages;
    OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id}->{tx} = $fake_ws_tx;

    OpenQA::Scheduler::Model::Jobs->new->_assign_multiple_jobs_to_worker(\@jobs, $worker, \@job_sequence, \@job_ids);

    is(scalar @$sent_messages, 1, 'exactly one message sent');
    is(ref(my $json     = $sent_messages->[0]->{json}), 'HASH', 'json data sent');
    is(ref(my $job_info = $json->{job_info}),           'HASH', 'job info sent') or diag explain $sent_messages;
    is($json->{type},                   'grab_jobs', 'event type present');
    is($job_info->{assigned_worker_id}, $worker_id,  'worker ID present');
    is_deeply($job_info->{ids},                 \@job_ids,      'job IDs present');
    is_deeply($job_info->{sequence},            \@job_sequence, 'job sequence present');
    is_deeply([sort keys %{$job_info->{data}}], \@job_ids,      'data for all jobs present');

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

sub list_jobs {
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(@_)->all]
}

sub job_get { $schema->resultset('Jobs')->find(shift) }

sub job_get_deps_rs {
    my ($id) = @_;
    my $job
      = $schema->resultset("Jobs")->search({'me.id' => $id}, {prefetch => ['settings', 'parents', 'children']})->first;
    $job->discard_changes;
    return $job;
}

sub job_get_deps { job_get_deps_rs(@_)->to_hash(deps => 1) }

# clean up fixture scheduled - we want our owns
job_get_deps_rs(99927)->delete;
job_get_deps_rs(99928)->delete;
# remove unrelated workers from fixtures
$schema->resultset('Workers')->delete;

my %settings = (
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => '666',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64',
    NICTYPE     => 'tap'
);
my %workercaps = (
    cpu_modelname                => 'Rainbow CPU',
    cpu_arch                     => 'x86_64',
    cpu_opmode                   => '32-bit, 64-bit',
    mem_max                      => '4096',
    isotovideo_interface_version => WEBSOCKET_API_VERSION,
    websocket_api_version        => WEBSOCKET_API_VERSION,
    worker_class                 => 'qemu_x86_64',
);

# parallel dependencies:
# A <--- D <--- E
#              /
# B <--- C <--/
#        ^
#        \--- F
my %settingsA = (%settings, TEST => 'A');
my %settingsB = (%settings, TEST => 'B');
my %settingsC = (%settings, TEST => 'C');
my %settingsD = (%settings, TEST => 'D');
my %settingsE = (%settings, TEST => 'E');
my %settingsF = (%settings, TEST => 'F');

sub _job_create {
    my ($settings, $parallel_jobs, $start_after_jobs, $start_directly_after_jobs) = @_;
    $settings->{_PARALLEL_JOBS}             = $parallel_jobs             if $parallel_jobs;
    $settings->{_START_AFTER_JOBS}          = $start_after_jobs          if $start_after_jobs;
    $settings->{_START_DIRECTLY_AFTER_JOBS} = $start_directly_after_jobs if $start_directly_after_jobs;
    my $job = $schema->resultset('Jobs')->create_from_settings($settings);
    # reload all values from database so we can check against default values
    $job->discard_changes;
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

my $jobA = _job_create(\%settingsA);

my $jobB = _job_create(\%settingsB);
my $jobC = _job_create(\%settingsC, [$jobB->id]);
my $jobD = _job_create(\%settingsD, [$jobA->id]);
my $jobE = _job_create(\%settingsE, $jobC->id . ',' . $jobD->id);    # test also IDs passed as comma separated string
my $jobF = _job_create(\%settingsF, [$jobC->id]);

$jobA->set_prio(3);
$jobB->set_prio(2);
$jobC->set_prio(4);
$_->set_prio(1) for ($jobD, $jobE, $jobF);

use OpenQA::WebAPI::Controller::API::V1::Worker;
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;

my @worker_ids             = map { $c->_register($schema, 'host', "$_", \%workercaps) } (1 .. 6);
my @jobs_in_expected_order = (
    $jobB => 'lowest prio of jobs without parents',
    $jobC => 'direct child of B',
    $jobF => 'direct child of C',
    $jobA => 'E is direct child of C, but A and D must be started first. A was picked',
    $jobD => 'direct child of A. D is picked',
    $jobE => 'C and D are now running so we can start E. E is picked',
);

# diag "A : " . $jobA->id;
# diag "B : " . $jobB->id;
# diag "C : " . $jobC->id;
# diag "D : " . $jobD->id;
# diag "E : " . $jobE->id;
# diag "F : " . $jobF->id;

schedule();

for my $i (0 .. 5) {
    my $job = $sent->{job}->{$jobs_in_expected_order[$i * 2]->id}->{job};
    ok(defined $job, $jobs_in_expected_order[$i * 2 + 1]) or die;
    $job = $job->to_hash;
    is($sent->{job}->{$jobs_in_expected_order[$i * 2]->id}->{jobhash}->{settings}->{NICVLAN},
        1, 'same vlan for whole group');
}

my $exp_cluster_jobs = {
    $jobA->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [$jobD->id],
        parallel_parents          => [],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
    $jobB->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [$jobC->id],
        parallel_parents          => [],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
    $jobC->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [$jobE->id, $jobF->id],
        parallel_parents          => [$jobB->id],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
    $jobD->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [$jobE->id],
        parallel_parents          => [$jobA->id],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
    $jobE->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [],
        parallel_parents          => [$jobC->id, $jobD->id],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
    $jobF->id => {
        chained_children          => [],
        chained_parents           => [],
        parallel_children         => [],
        parallel_parents          => [$jobC->id],
        directly_chained_children => [],
        directly_chained_parents  => [],
    },
};
# it shouldn't matter which job we ask - they should all restart the same cluster
is_deeply($jobA->cluster_jobs, $exp_cluster_jobs, "Job A has proper infos");
is($jobA->blocked_by_id, undef, "JobA is unblocked");
is_deeply($jobB->cluster_jobs, $exp_cluster_jobs, "Job B has proper infos");
is($jobB->blocked_by_id, undef, "JobB is unblocked");
is_deeply($jobC->cluster_jobs, $exp_cluster_jobs, "Job C has proper infos");
is($jobC->blocked_by_id, undef, "JobC is unblocked");
is_deeply($jobD->cluster_jobs, $exp_cluster_jobs, "Job D has proper infos");
is($jobD->blocked_by_id, undef, "JobD is unblocked");
is_deeply($jobE->cluster_jobs, $exp_cluster_jobs, "Job E has proper infos");
is($jobE->blocked_by_id, undef, "JobE is unblocked");
is_deeply($jobF->cluster_jobs, $exp_cluster_jobs, "Job F has proper infos");
is($jobF->blocked_by_id, undef, "JobF is unblocked");

# jobA failed
my $result = $jobA->done(result => 'failed');
is($result, 'failed', 'job_set_done');

# reload changes from DB - jobs should be cancelled by failed jobA
$_->discard_changes for ($jobD, $jobE);
# this should not change the result which is parallel_failed due to failed jobA
$result = $jobD->done(result => 'incomplete');
is($result, 'incomplete', 'job_set_done on D');
$result = $jobE->done(result => 'incomplete');
is($result, 'incomplete', 'job_set_done on E');

my $job = job_get_deps($jobA->id);
is($job->{state},  DONE,   'job_set_done changed state');
is($job->{result}, FAILED, 'job_set_done changed result');

$job = job_get_deps($jobB->id);
is($job->{state}, RUNNING, 'job_set_done changed state');

$job = job_get_deps($jobC->id);
is($job->{state}, RUNNING, 'job_set_done changed state');

$job = job_get_deps($jobD->id);
is($job->{state},  DONE,            'job_set_done changed state');
is($job->{result}, PARALLEL_FAILED, 'job_set_done changed result, jobD failed because of jobA');

$job = job_get_deps($jobE->id);
is($job->{state},  DONE,            'job_set_done changed state');
is($job->{result}, PARALLEL_FAILED, 'job_set_done changed result, jobE failed because of jobD');

$jobF->discard_changes;
$job = job_get_deps($jobF->id);
is($job->{state}, RUNNING, 'job_set_done changed state');

# check MM API for children status - available only for running jobs
my $worker = $schema->resultset("Workers")->find($worker_ids[1]);
my $t      = Test::Mojo->new('OpenQA::WebAPI');

my $job_token = $sent->{job}->{$jobC->id}->{worker}->get_property('JOBTOKEN');
isnt($job_token, undef, 'JOBTOKEN is present');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $job_token);
    });
$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id])
  ->or(sub { diag explain $t->tx->res->content });
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => [])
  ->or(sub { diag explain $t->tx->res->content });
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id])
  ->or(sub { diag explain $t->tx->res->content });

# duplicate jobF, the full cluster is duplicated too
my $id = $jobF->auto_duplicate;
ok(defined $id, "duplicate works");

$job = job_get_deps($jobA->id);    # cloned
is($job->{state},  DONE,   'no change');
is($job->{result}, FAILED, 'no change');
ok(defined $job->{clone_id}, 'cloned');

$job = job_get_deps($jobB->id);    # cloned
is($job->{result}, "parallel_failed", "$job->{id} B stopped");
ok(defined $job->{clone_id}, 'cloned');
my $jobB2 = $job->{clone_id};

$job = job_get_deps($jobC->id);    # cloned
is($job->{state}, RUNNING, 'no change');
ok(defined $job->{clone_id}, 'cloned');
my $jobC2 = $job->{clone_id};

$job = job_get_deps($jobD->id);    # cloned
is($job->{state},  DONE,              'no change');
is($job->{result}, "parallel_failed", 'no change');
ok(defined $job->{clone_id}, 'cloned');

$job = job_get_deps($jobE->id);    # cloned
is($job->{state},  DONE,              'no change');
is($job->{result}, "parallel_failed", 'no change');
ok(defined $job->{clone_id}, 'cloned');

$job = job_get_deps($jobF->id);    # cloned
is($job->{state}, RUNNING, 'no change');
ok(defined $job->{clone_id}, 'cloned');
my $jobF2 = $job->{clone_id};

$job = job_get_deps($jobB2);
is($job->{state},    SCHEDULED, "cloned jobs are scheduled");
is($job->{clone_id}, undef,     'no clones');

$job = job_get_deps($jobC2);
is($job->{state},    SCHEDULED, "cloned jobs are scheduled");
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [$jobB2], Chained => [], 'Directly chained' => []}, "cloned deps");

$job = job_get_deps($jobF2);
is($job->{state},    SCHEDULED, "cloned jobs are scheduled");
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [$jobC2], Chained => [], 'Directly chained' => []}, "cloned deps");

# recheck that cloning didn't change MM API results children status
$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

$job = job_get_deps($jobA->id);    # cloned
is($job->{state},  DONE,   'no change');
is($job->{result}, FAILED, 'no change');
ok(defined $job->{clone_id}, 'cloned');
my $jobA2 = $job->{clone_id};

$job = job_get_deps($jobB->id);    # unchanged
is($job->{result},   "parallel_failed", "B is unchanged");
is($job->{clone_id}, $jobB2,            'cloned');

$job = job_get_deps($jobC->id);    # unchanged
is($job->{state},    RUNNING,           'no change');
is($job->{result},   "parallel_failed", "C is restarted");
is($job->{clone_id}, $jobC2,            'cloned');

$job = job_get_deps($jobD->id);    #cloned
is($job->{state},  DONE,              'no change');
is($job->{result}, "parallel_failed", 'no change');
ok(defined $job->{clone_id}, 'cloned');
my $jobD2 = $job->{clone_id};

$job = job_get_deps($jobE->id);    #cloned
is($job->{state},  DONE,              'no change');
is($job->{result}, "parallel_failed", 'no change');
ok(defined $job->{clone_id}, 'cloned');
my $jobE2 = $job->{clone_id};

$job = job_get_deps($jobF->id);    # unchanged
is($job->{state},    RUNNING, 'no change');
is($job->{clone_id}, $jobF2,  'cloned');

$job = job_get_deps($jobA2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, "cloned deps");

$job = job_get_deps($jobB2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, "cloned deps");

$job = job_get_deps($jobC2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [$jobB2], Chained => [], 'Directly chained' => []}, "cloned deps");


$job = job_get_deps($jobD2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [$jobA2], Chained => [], 'Directly chained' => []}, "cloned deps");

$job = job_get_deps($jobE2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply([sort @{$job->{parents}->{Parallel}}], [sort ($jobC2, $jobD2)], "cloned deps");

$job = job_get_deps($jobF2);
is($job->{state},    SCHEDULED, 'no change');
is($job->{clone_id}, undef,     'no clones');
is_deeply($job->{parents}, {Parallel => [$jobC2], Chained => [], 'Directly chained' => []}, "cloned deps");

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

# recheck that cloning didn't change MM API results children status
$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

# now the cloned group should be scheduled
# we already called job_set_done on jobE, so worker 6 is available

#diag "A2 : $jobA2";
#diag "B2 : $jobB2";
#diag "C2 : $jobC2";
#diag "D2 : $jobD2";
#diag "E2 : $jobE2";
#diag "F2 : $jobF2";

# We have 3 free workers (as B,C and F are still running)
# and the cluster is 6, so we expect nothing to be SCHEDULED
schedule();
is(job_get_deps($jobA2)->{state}, SCHEDULED, 'job still scheduled');

# now free two of them and create one more worker. So that we
# have 6 free, but have vlan 1 still busy
$_->done(result => 'passed') for ($jobC, $jobF);
$c->_register($schema, 'host', "10", \%workercaps);
schedule();

ok(exists $sent->{job}->{$jobA2}, " $jobA2 was assigned ") or die "A2 $jobA2 wasn't scheduled";
$job = $sent->{job}->{$jobA2}->{jobhash};
is($job->{id},                  $jobA2, "jobA2");                                #lowest prio of jobs without parents
is($job->{settings}->{NICVLAN}, 2,      "different vlan") or die explain $job;

ok(exists $sent->{job}->{$jobB2}, " $jobB2 was assigned ") or die "B2 $jobB2 wasn't scheduled";
$job = $sent->{job}->{$jobB2}->{job}->to_hash;
is($job->{id}, $jobB2, "jobB2");                                                 #lowest prio of jobs without parents

is($job->{settings}->{NICVLAN}, 2, "different vlan") or die explain $job;

$jobB->done(result => 'passed');
job_get($_)->done(result => 'passed') for ($jobA2, $jobB2, $jobC2, $jobD2, $jobE2, $jobF2);

$jobA = _job_create(\%settingsA);
$jobB = _job_create(\%settingsB);
$jobC = _job_create(\%settingsC, [$jobB->id]);
$jobD = _job_create(\%settingsD, [$jobA->id]);
$jobE = _job_create(\%settingsE, $jobC->id . ',' . $jobD->id);    # test also IDs passed as comma separated string
$jobF = _job_create(\%settingsF, [$jobC->id]);
is($jobA->blocked_by_id, undef, "JobA is unblocked");
is($jobB->blocked_by_id, undef, "JobB is unblocked");
is($jobC->blocked_by_id, undef, "JobC is unblocked");
is($jobD->blocked_by_id, undef, "JobD is unblocked");
is($jobE->blocked_by_id, undef, "JobE is unblocked");
is($jobF->blocked_by_id, undef, "JobF is unblocked");
$c->_register($schema, 'host', "15", \%workercaps);
$c->_register($schema, 'host', "16", \%workercaps);
$c->_register($schema, 'host', "17", \%workercaps);
$c->_register($schema, 'host', "18", \%workercaps);
schedule();
$job = $sent->{job}->{$jobD->id}->{job}->to_hash;
# all vlans are free so we take the first
is($job->{settings}->{NICVLAN}, 1, "reused vlan") or die explain $job;




## check CHAINED dependency cloning
my %settingsX = %settings;
$settingsX{TEST} = 'X';
my $jobX = _job_create(\%settingsX);

my %settingsY = %settings;
$settingsY{TEST}              = 'Y';
$settingsY{_START_AFTER_JOBS} = [$jobX->id];
my $jobY = _job_create(\%settingsY);

is($jobX->done(result => 'passed'), 'passed', 'jobX set to done');
# since we are skipping job_grab, reload missing columns from DB
$jobX->discard_changes;

# current state:
# X <---- Y
# done    sch.

is_deeply(
    $jobY->to_hash(deps => 1)->{parents},
    {Chained => [$jobX->id], Parallel => [], 'Directly chained' => []},
    "JobY parents fit"
);
# when Y is scheduled and X is duplicated, Y must be cancelled and Y2 needs to depend on X2
my $jobX2 = $jobX->auto_duplicate;
$jobY->discard_changes;
is($jobY->state,  CANCELLED,          'jobY was cancelled');
is($jobY->result, PARALLEL_RESTARTED, 'jobY was skipped');
my $jobY2 = $jobY->clone;
ok(defined $jobY2, "jobY was cloned too");
is($jobY2->blocked_by_id, $jobX2->id, "JobY2 is blocked");
is_deeply(
    $jobY2->to_hash(deps => 1)->{parents},
    {Chained => [$jobX2->id], Parallel => [], 'Directly chained' => []},
    "JobY parents fit"
);
is($jobX2->id,    $jobY2->parents->single->parent_job_id, 'jobY2 parent is now jobX clone');
is($jobX2->clone, undef,                                  "no clone");
is($jobY2->clone, undef,                                  "no clone");

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
isnt($jobY2->clone_id, undef, "child job Y2 has been cloned together with parent X2");

my $jobY3_id = $jobY2->clone_id;
my $jobY3    = job_get_deps($jobY3_id);
is($jobY2->clone->blocked_by_id, $jobX3->id, "jobY3 blocked");
is_deeply(
    $jobY3->{parents},
    {Chained => [$jobX3->id], Parallel => [], 'Directly chained' => []},
    'jobY3 parent is now jobX3'
);

# checking siblings scenario
# original state, all job set as running
# H <-(parallel) J
# ^             ^
# | (parallel)  | (parallel)
# K             L
my %settingsH = (%settings, TEST => 'H');
my %settingsJ = (%settings, TEST => 'J');
my %settingsK = (%settings, TEST => 'K');
my %settingsL = (%settings, TEST => 'L');

my $jobH = _job_create(\%settingsH);
my $jobK = _job_create(\%settingsK, [$jobH->id]);
my $jobJ = _job_create(\%settingsJ, [$jobH->id]);
my $jobL = _job_create(\%settingsL, [$jobJ->id]);

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
ok($jobJ->clone, 'jobJ cloned');
ok($jobH->clone, 'jobH cloned');
ok($jobK->clone, 'jobK cloned');

my $jobJ2 = $jobL2->to_hash(deps => 1)->{parents}->{Parallel}->[0];
is($jobJ2, $jobJ->clone->id, 'J2 cloned with parallel parent dep');
my $jobH2 = job_get_deps($jobJ2)->{parents}->{Parallel}->[0];
is($jobH2, $jobH->clone->id, 'H2 cloned with parallel parent dep');
is_deeply(
    job_get_deps($jobH2)->{children}->{Parallel},
    [$jobK->clone->id, $jobJ2],
    'K2 cloned with parallel children dep'
);

# checking all-in mixed scenario
# create original state (excluding TA which is just the same as T just directly chained to Q):
# Q <- (chained) W <-\ (parallel)
#   ^- (chained) U <-- (parallel) T
#   ^- (chained) R <-/ (parallel) | (chained)
#   ^-----------------------------/
#
# Q is done; W,U,R and T is running
my %settingsQ  = (%settings, TEST => 'Q');
my %settingsW  = (%settings, TEST => 'W');
my %settingsU  = (%settings, TEST => 'U');
my %settingsR  = (%settings, TEST => 'R');
my %settingsT  = (%settings, TEST => 'T');
my %settingsTA = (%settings, TEST => 'TA');
my $jobQ       = _job_create(\%settingsQ);
my $jobW = _job_create(\%settingsW, undef, [$jobQ->id]);
my $jobU = _job_create(\%settingsU, undef, [$jobQ->id]);
my $jobR = _job_create(\%settingsR, undef, [$jobQ->id]);
my $jobT  = _job_create(\%settingsT, [$jobW->id, $jobU->id, $jobR->id], [$jobQ->id]);
my $jobTA = _job_create(\%settingsTA, [$jobW->id, $jobU->id, $jobR->id], undef, [$jobQ->id]);

# check dependencies of job Q
my $jobQ_deps  = job_get_deps($jobQ->id);
my @sorted_got = sort(@{$jobQ_deps->{children}->{Chained}});
my @sorted_exp = sort(($jobW->id, $jobU->id, $jobR->id, $jobT->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is chained parent to all jobs except jobTA') or diag explain \@sorted_got;
@sorted_got = sort(@{$jobQ_deps->{children}->{'Directly chained'}});
@sorted_exp = sort(($jobTA->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is directly chained parent to jobTA') or diag explain \@sorted_got;
is($jobT->blocked_by_id,  $jobQ->id, 'JobT is blocked by job supposed to run before');
is($jobTA->blocked_by_id, $jobQ->id, 'JobT2 is blocked by job supposed to run *directly* before');
is($jobW->blocked_by_id,  $jobQ->id, 'JobW is blocked by job supposed to run before');

# note: Maybe the blocked_by behavior for jobs to run *directly* after each other needs to be changed
#       later. Neverthless, let's explicitly assert this behavior so we know what we have right now.

# hack jobs to appear to scheduler in desired state
_jobs_update_state([$jobQ],                              DONE);
_jobs_update_state([$jobW, $jobU, $jobR, $jobT, $jobTA], RUNNING);

# duplicate job U
# expected state (excluding TA2 which is just the same as T2 just directly chained to Q):
# Q <- (chained) W2 <-\ (parallel)
#   ^- (chained) E2 <-- (parallel) T2
#   ^- (chained) R2 <-/ (parallel) | (chained)
#   ^------------------------------/
#
# Q is done; W2,E2,R2, T2 and TA2 are scheduled
my $jobU2 = $jobU->auto_duplicate;
ok($jobU2, 'jobU duplicated');

# reload data from DB
$_->discard_changes for ($jobQ, $jobW, $jobU, $jobR, $jobT, $jobTA);

# check whether jobs have been cloned
ok(!$jobQ->clone, 'jobQ not cloned');
ok($jobW->clone,  'jobW cloned');
ok($jobU->clone,  'jobU cloned');
ok($jobR->clone,  'jobR cloned');
ok($jobT->clone,  'jobT cloned');
ok($jobTA->clone, 'jobTA cloned');

# check whether dependencies contain cloned jobs as well
$jobQ = job_get_deps($jobQ->id);
my $jobW2  = job_get_deps($jobW->clone->id);
my $jobR2  = job_get_deps($jobR->clone->id);
my $jobT2  = job_get_deps($jobT->clone->id);
my $jobTA2 = job_get_deps($jobTA->clone->id);

print("jobTA: " . $jobTA->id . "\n");
print("jobTA2: " . $jobTA2->{id} . "\n");

@sorted_got = sort(@{$jobQ->{children}->{Chained}});
@sorted_exp
  = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}, $jobT2->{id}, $jobW->id, $jobU->id, $jobR->id, $jobT->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is chained parent to all jobs except jobTA/jobTA2')
  or diag explain \@sorted_got;
# note: I have no idea why $jobTA and its clone $jobTA2 appear as regular chained dependencies.

@sorted_got = sort(@{$jobQ->{children}->{'Directly chained'}});
@sorted_exp = sort(($jobTA2->{id}, $jobTA->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is directly chained parent to jobTA and its clone jobTA2')
  or diag explain \@sorted_got;

@sorted_got = sort(@{$jobTA2->{parents}->{'Directly chained'}});
@sorted_exp = sort(($jobQ->{id}));
is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 directly chained after jobQ') or diag explain \@sorted_got;

@sorted_got = sort(@{$jobTA2->{parents}->{'Chained'}});
@sorted_exp = sort(());
is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 not regularily chained after jobQ') or diag explain \@sorted_got;

@sorted_got = sort(@{$jobTA2->{parents}->{'Directly chained'}});
@sorted_exp = sort(($jobQ->{id}));
is_deeply(\@sorted_got, \@sorted_exp, 'jobTA2 directly chained after jobQ') or diag explain \@sorted_got;

@sorted_got = sort(@{$jobT2->{parents}->{Parallel}});
@sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}));
is_deeply(\@sorted_got, \@sorted_exp, 'jobT is parallel child of all jobs except jobQ') or diag explain \@sorted_got;

@sorted_got = sort(@{$jobTA2->{parents}->{Parallel}});
is_deeply(\@sorted_got, \@sorted_exp, 'jobTA is parallel child of all jobs except jobQ') or diag explain \@sorted_got;

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

is_deeply(
    $jobW2->{parents},
    {Chained => [$jobQ->{id}], Parallel => [], 'Directly chained' => []},
    'jobW2 has no parent dependency to sibling'
) or diag explain $jobW2->{parents};
is_deeply(
    $jobU2->to_hash(deps => 1)->{parents},
    {Chained => [$jobQ->{id}], Parallel => [], 'Directly chained' => []},
    'jobU2 has no parent dependency to sibling'
) or diag explain $jobU2->to_hash(deps => 1)->{parents};
is_deeply(
    $jobR2->{parents},
    {Chained => [$jobQ->{id}], Parallel => [], 'Directly chained' => []},
    'jobR2 has no parent dependency to sibling'
) or diag explain $jobR2->{parents};

# check cloning of clones
# this is to check whether duplication propely travers clones to find latest clone
# test is divided into two parts, cloning jobO and then jobI

# original state, all jobs DONE
#
# P <-(parallel) O <-(parallel) I
#
my %settingsP = (%settings, TEST => 'P');
my %settingsO = (%settings, TEST => 'O');
my %settingsI = (%settings, TEST => 'I');

my $jobP = _job_create(\%settingsP);
my $jobO = _job_create(\%settingsO, [$jobP->id]);
my $jobI = _job_create(\%settingsI, [$jobO->id]);

# hack jobs to appear to scheduler in desired state
_jobs_update_state([$jobP, $jobO, $jobI], DONE);

# cloning O gets to expected state
#
# P2 <-(parallel) O2 (clone of) O <-(parallel) I2
#
my $jobO2 = $jobO->auto_duplicate;
ok($jobO2, 'jobO duplicated');
# reload data from DB
$_->discard_changes for ($jobP, $jobO, $jobI);
# check other clones
ok($jobP->clone, 'jobP cloned');
ok($jobO->clone, 'jobO cloned');
ok($jobI->clone, 'jobI cloned');

$jobO2 = job_get_deps($jobO2->id);
$jobI  = job_get_deps($jobI->id);
my $jobI2 = job_get_deps($jobI->{clone_id});
my $jobP2 = job_get_deps($jobP->clone->id);

is_deeply($jobI->{parents}->{Parallel},  [$jobO->id],    'jobI retain its original parent');
is_deeply($jobI2->{parents}->{Parallel}, [$jobO2->{id}], 'jobI2 got new parent');
is_deeply($jobO2->{parents}->{Parallel}, [$jobP2->{id}], 'clone jobO2 gets new parent jobP2');

# get Jobs RS from ids for cloned jobs
$jobO2 = $schema->resultset('Jobs')->search({id => $jobO2->{id}})->single;
$jobP2 = $schema->resultset('Jobs')->search({id => $jobP2->{id}})->single;
$jobI2 = $schema->resultset('Jobs')->search({id => $jobI2->{id}})->single;
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

$jobI2 = job_get_deps($jobI2->id);
my $jobO3 = job_get_deps($jobO2->clone->id);
my $jobP3 = job_get_deps($jobP2->clone->id);

is_deeply($jobI2->{parents}->{Parallel}, [$jobO3->{id}], 'jobI2 got new parent jobO3');
is_deeply($jobO3->{parents}->{Parallel}, [$jobP3->{id}], 'clone jobO3 gets new parent jobP3');

# https://progress.opensuse.org/issues/10456
%settingsA = (%settings, TEST => '116539');
%settingsB = (%settings, TEST => '116569');
%settingsC = (%settings, TEST => '116570');
%settingsD = (%settings, TEST => '116571');

$jobA = _job_create(\%settingsA);
$jobB = _job_create(\%settingsB, undef, [$jobA->id]);
$jobC = _job_create(\%settingsC, undef, [$jobA->id]);
$jobD = _job_create(\%settingsD, undef, [$jobA->id]);

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
my $jobBc_h = job_get_deps($jobBc->id);
is_deeply($jobBc_h->{parents}->{Chained}, [$jobA->id], 'jobBc has jobA as chained parent');
is($jobBc_h->{settings}{TEST}, $jobB->TEST, 'jobBc test and jobB test are equal');

ok(!$jobC->clone, 'jobC was not cloned');
my $jobC_h = job_get_deps($jobC->id);
is_deeply($jobC_h->{parents}->{Chained}, [$jobA->id], 'jobC has jobA as chained parent');
is($jobC_h->{settings}{TEST}, $jobC->TEST, 'jobBc test and jobB test are equal');

ok(!$jobD->clone, 'jobD was not cloned');
my $jobD_h = job_get_deps($jobD->id);
is_deeply($jobD_h->{parents}->{Chained}, [$jobA->id], 'jobD has jobA as chained parent');
is($jobD_h->{settings}{TEST}, $jobD->TEST, 'jobBc test and jobB test are equal');

# hack jobs to appear running to scheduler
$jobB->clone->state(RUNNING);
$jobB->clone->update;

# clone A
$jobA->discard_changes;
ok(!$jobA->clone, "jobA not yet cloned");
$jobA2 = $jobA->auto_duplicate;
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
my $jobB2_h = job_get_deps($jobB->clone->clone->clone->id);
is_deeply($jobB2_h->{parents}->{Chained}, [$jobA2->id], 'jobB2 has jobA2 as chained parent');
is($jobB2_h->{settings}{TEST}, $jobB->TEST, 'jobB2 test and jobB test are equal');

ok($jobC->clone, 'jobC was cloned');
my $jobC2_h = job_get_deps($jobC->clone->clone->id);
is_deeply($jobC2_h->{parents}->{Chained}, [$jobA2->id], 'jobC2 has jobA2 as chained parent');
is($jobC2_h->{settings}{TEST}, $jobC->TEST, 'jobC2 test and jobC test are equal');

ok($jobD->clone, 'jobD was cloned');
my $jobD2_h = job_get_deps($jobD->clone->clone->id);
is_deeply($jobD2_h->{parents}->{Chained}, [$jobA2->id], 'jobD2 has jobA2 as chained parent');
is($jobD2_h->{settings}{TEST}, $jobD->TEST, 'jobD2 test and jobD test are equal');

my $jobA2_h = job_get_deps($jobA2->id);

# We are sorting here because is_deeply needs the elements to be with the same order
# and the DB query doesn't enforce any order
my @clone_deps = sort { $a <=> $b } @{$jobA2_h->{children}->{Chained}};
my @deps       = sort { $a <=> $b } ($jobB2_h->{id}, $jobC2_h->{id}, $jobD2_h->{id});
is_deeply(\@clone_deps, \@deps, 'jobA2 has jobB2, jobC2 and jobD2 as children');

# situation parent is done, children running -> parent is cloned -> parent is running -> parent is cloned. Check all children has new parent:
# A <- B
#   |- C
#   \- D
%settingsA = (%settings, TEST => '116539A');
%settingsB = (%settings, TEST => '116569A');
%settingsC = (%settings, TEST => '116570A');
%settingsD = (%settings, TEST => '116571A');

$jobA = _job_create(\%settingsA);
$jobB = _job_create(\%settingsB, undef, [$jobA->id]);
$jobC = _job_create(\%settingsC, undef, [$jobA->id]);
$jobD = _job_create(\%settingsD, undef, [$jobA->id]);

# hack jobs to appear done to scheduler
_jobs_update_state([$jobA], DONE, PASSED);
_jobs_update_state([$jobB, $jobC, $jobD], RUNNING);

$jobA2 = $jobA->auto_duplicate;
$_->discard_changes for ($jobA, $jobB, $jobC, $jobD);
# check all children were cloned and has $jobA as parent
for ($jobB, $jobC, $jobD) {
    ok($_->clone, 'job cloned');
    my $h = job_get_deps($_->clone->id);
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
    my $h = job_get_deps($_->clone->clone->id);
    is_deeply($h->{parents}{Chained}, [$jobA3->id], 'job has jobA3 as parent');
}

# situation: chained parent is done, children are all failed and has parallel dependency to the first sibling
#    /- C
#    |  |
# A <-- B
#    |  |
#    \- D
%settingsA = (%settings, TEST => '360-A');
%settingsB = (%settings, TEST => '360-B');
%settingsC = (%settings, TEST => '360-C');
%settingsD = (%settings, TEST => '360-D');

my $duplicate_test = sub {
    $jobA = _job_create(\%settingsA);
    $jobB = _job_create(\%settingsB, undef, [$jobA->id]);
    $jobC = _job_create(\%settingsC, [$jobB->id], [$jobA->id]);
    $jobD = _job_create(\%settingsD, [$jobB->id], [$jobA->id]);

    # hack jobs to appear done to scheduler
    _jobs_update_state([$jobA],               DONE, PASSED);
    _jobs_update_state([$jobB, $jobC, $jobD], DONE, FAILED);

    $jobA2 = $jobA->auto_duplicate;
    $_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

    # check all children were cloned and has $jobA as parent
    for ($jobB, $jobC, $jobD) {
        ok($_->clone, 'job cloned');
        my $h = job_get_deps($_->clone->id);
        is_deeply($h->{parents}{Chained}, [$jobA2->id], 'job has jobA2 as parent') or explain($h->{parents}{Chained});
    }

    for ($jobC, $jobD) {
        my $h = job_get_deps($_->clone->id);
        is_deeply($h->{parents}{Parallel}, [$jobB->clone->id], 'job has jobB2 as parallel parent');
    }
};

sub _job_create_set_done {
    my ($settings, $state) = @_;
    my $job = _job_create($settings);
    # hack jobs to appear done to scheduler
    _jobs_update_state([$job], $state, PASSED);
    return $job;
}

sub _job_cloned_and_related {
    my ($jobA, $jobB) = @_;
    ok($jobA->clone, 'jobA has a clone');
    my $jobA_hash   = job_get_deps($jobA->id);
    my $cloneA_hash = job_get_deps($jobA->clone->id);
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
    my %settingsSUS = %settings;
    $settingsSUS{TEST} = 'SupportServer';
    my %settingsAS = %settings;
    $settingsAS{TEST} = 'AdminServer';
    my %settingsBS = %settings;
    $settingsBS{TEST} = 'BranchServer';
    my %settingsIS = %settings;
    $settingsIS{TEST} = 'ImageServer';
    my %settingsIS2 = %settings;
    $settingsIS2{TEST} = 'ImageServer2';
    my %settingsT = %settings;
    $settingsT{TEST} = 'Terminal';

    # Support server
    my $jobSUS = _job_create_set_done(\%settingsSUS, DONE);
    # Admin Server 1
    $settingsAS{_PARALLEL_JOBS} = [$jobSUS->id];
    my $jobAS = _job_create_set_done(\%settingsAS, DONE);
    # Image server 2
    $settingsIS2{_START_AFTER_JOBS} = [$jobAS->id];
    my $jobIS2 = _job_create_set_done(\%settingsIS2, DONE);
    # Image server
    $settingsIS{_PARALLEL_JOBS}    = [$jobSUS->id];
    $settingsIS{_START_AFTER_JOBS} = [$jobAS->id];
    my $jobIS = _job_create_set_done(\%settingsIS, CANCELLED);
    # Branch server
    $settingsBS{_PARALLEL_JOBS} = [$jobAS->id, $jobSUS->id];
    my $jobBS = _job_create_set_done(\%settingsBS, DONE);
    # Terminal
    $settingsT{_PARALLEL_JOBS} = [$jobBS->id];
    my $jobT = _job_create_set_done(\%settingsT, DONE);
    # clone terminal
    $jobT->duplicate;
    $_->discard_changes for ($jobSUS, $jobAS, $jobIS, $jobIS2, $jobBS, $jobT);
    # check dependencies of clones
    ok(_job_cloned_and_related($jobSUS, $jobAS),  "jobSUS and jobAS");
    ok(_job_cloned_and_related($jobSUS, $jobIS),  "jobSUS and jobIS");
    ok(_job_cloned_and_related($jobSUS, $jobBS),  "jobSUS and jobBS");
    ok(_job_cloned_and_related($jobAS,  $jobIS),  "jobAS and jobIS");
    ok(_job_cloned_and_related($jobAS,  $jobIS2), "jobAS and jobIS2");
    ok(_job_cloned_and_related($jobAS,  $jobBS),  "jobAS and jobBS");
    ok(_job_cloned_and_related($jobBS,  $jobT),   "jobBS and jobT");
};

# This enforces order in the processing of the nodes, to test PR#1623
my $unordered_sort = \&OpenQA::Jobs::Constants::search_for;
my $ordered_sort   = sub {
    return $unordered_sort->(@_)->search(undef, {order_by => {-desc => 'id'}});
};

my %tests = ('duplicate' => $duplicate_test, 'slepos test workers' => $slepos_test_workers);
while (my ($k, $v) = each %tests) {
    no warnings 'redefine';
    *OpenQA::Jobs::Constants::search_for = $unordered_sort;
    subtest "$k unordered" => $v;
    *OpenQA::Jobs::Constants::search_for = $ordered_sort;
    subtest "$k ordered" => $v;
}

subtest "SAP setup - issue 52928" => sub {
    my %settingsA = %settings;
    $settingsA{TEST} = 'hdd_gnome';
    my %settingsB = %settings;
    $settingsB{TEST}             = 'gnome_netweaver';
    $settingsB{START_AFTER_TEST} = 'hdd_gnome';
    my %settingsC = %settings;
    $settingsC{TEST} = 'hdd_textmode';
    my %settingsD = %settings;
    $settingsD{TEST}             = 'textmode_netweaver';
    $settingsD{START_AFTER_TEST} = 'hdd_textmode,gnome_netweaver';
    my %settingsE = %settings;
    $settingsE{TEST} = 'node1';
    my %settingsF = %settings;
    $settingsF{TEST} = 'node2';
    my %settingsG = %settings;
    $settingsG{TEST}             = 'supportserver';
    $settingsG{START_AFTER_TEST} = 'textmode_netweaver,hdd_textmode';
    $settingsG{PARALLEL_WITH}    = 'node1,node2';
    my %settingsH = %settings;
    $settingsH{TEST}             = 'final';
    $settingsH{START_AFTER_TEST} = 'supportserver,hdd_gnome';

    my $jobA = _job_create_set_done(\%settingsA, DONE);
    $settingsB{_START_AFTER_JOBS} = [$jobA->id];
    my $jobB = _job_create(\%settingsB);
    my $jobC = _job_create_set_done(\%settingsC, DONE);
    $settingsD{_START_AFTER_JOBS} = [$jobC->id, $jobB->id];
    my $jobD = _job_create(\%settingsD);
    my $jobE = _job_create(\%settingsE);
    my $jobF = _job_create(\%settingsF);
    $settingsG{_START_AFTER_JOBS} = [$jobD->id, $jobC->id];
    $settingsG{_PARALLEL_JOBS}    = [$jobE->id, $jobF->id];
    my $jobG = _job_create(\%settingsG);
    $settingsH{_START_AFTER_JOBS} = [$jobG->id, $jobA->id];
    my $jobH = _job_create(\%settingsH);

    is($jobB->blocked_by_parent_job, undef);
    is($jobD->blocked_by_parent_job, $jobB->id);
    is($jobG->blocked_by_parent_job, $jobD->id);
};

ok $mock_send_called, 'mocked ws_send method has been called';

subtest 'WORKER_CLASS validated when creating directly chained dependencies' => sub {
    %settingsA = (%settings, TEST => 'chained-A', WORKER_CLASS => 'foo');
    %settingsB = (%settings, TEST => 'chained-B', WORKER_CLASS => 'bar');
    %settingsC = (%settings, TEST => 'chained-C');
    %settingsD = (%settings, TEST => 'chained-D', WORKER_CLASS => 'foo');
    $jobA      = _job_create(\%settingsA);
    is($jobA->settings->find({key => 'WORKER_CLASS'})->value, 'foo', 'job A has class foo');
    $jobB = _job_create(\%settingsB, undef, [$jobA->id]);
    is($jobB->settings->find({key => 'WORKER_CLASS'})->value,
        'bar', 'job B has different class bar (ok for regularily chained dependencies)');
    $jobC = _job_create(\%settingsC, undef, [], [$jobB->id]);
    is($jobC->settings->find({key => 'WORKER_CLASS'})->value, 'bar', 'job C inherits worker class from B');
    throws_ok(
        sub {
            $jobD = _job_create(\%settingsD, undef, [], [$jobC->id]);
        },
        qr/Specified WORKER_CLASS \(foo\) does not match the one from directly chained parent .* \(bar\)/,
        'creation of job with mismatching worker class prevented'
    );
};

subtest 'siblings of running for cluster' => sub {
    my $schedule = OpenQA::Scheduler::Model::Jobs->singleton;
    $schedule->scheduled_jobs->{99999}->{state}        = RUNNING;
    $schedule->scheduled_jobs->{99999}->{cluster_jobs} = {1 => 1, 2 => 1};
    my $mock = Test::MockModule->new('OpenQA::Scheduler::Model::Jobs');
    $mock->redefine(_jobs_in_execution => ($schema->resultset('Jobs')->search({id => 99999})->single));
    my ($allocated_jobs, $allocated_workers) = ({}, {});
    $schedule->_pick_siblings_of_running($allocated_jobs, $allocated_workers);
    ok $allocated_jobs,    'some jobs are allocated';
    ok $allocated_workers, 'jobs are allocated to workers';
};

done_testing();
