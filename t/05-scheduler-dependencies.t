#!/usr/bin/env perl -w

# Copyright (C) 2014-2017 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd dump);
use OpenQA::Scheduler::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use Test::Mojo;
use Test::More;
use Test::Warnings;
use OpenQA::Jobs::Constants;

my $schema = OpenQA::Test::Database->new->create();

# create Test DBus bus and service for fake WebSockets call
my $ws = OpenQA::WebSockets->new;

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(%args)->all];
}

sub job_get {
    my ($id) = @_;
    return $schema->resultset('Jobs')->find($id);
}

sub job_get_deps_rs {
    my ($id) = @_;
    my $job
      = $schema->resultset("Jobs")->search({'me.id' => $id}, {prefetch => ['settings', 'parents', 'children']})->first;
    $job->discard_changes;
    return $job;
}

sub job_get_deps {
    return job_get_deps_rs(@_)->to_hash(deps => 1);
}

my $current_jobs = list_jobs();
my %settings     = (
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
    websocket_api_version        => WEBSOCKET_API_VERSION
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
    my ($settings, $parallel_jobs, $start_after_jobs) = @_;
    $settings->{_PARALLEL_JOBS}    = $parallel_jobs    if $parallel_jobs;
    $settings->{_START_AFTER_JOBS} = $start_after_jobs if $start_after_jobs;
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

my @worker_ids = map { $c->_register($schema, 'host', "$_", \%workercaps) } (1 .. 6);
my @jobs_in_expected_order = (
    $jobB => 'lowest prio of jobs without parents',
    $jobC => 'direct child of B',
    $jobF => 'direct child of C',
    $jobA => 'E is direct child of C, but A and D must be started first',
    $jobD => 'direct child of A',
    $jobE => 'C and D are now running so we can start E',
);
for my $i (0 .. 5) {
    my $job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $worker_ids[$i], allocate => 1);
    is($job->{id}, ${jobs_in_expected_order [$i * 2]}->id, ${jobs_in_expected_order [$i * 2 + 1]});
    is($job->{settings}->{NICVLAN}, 1, 'same vlan for whole group');
}

my $exp_cluster_jobs = {
    $jobA->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [$jobD->id],
        parallel_parents  => [],
    },
    $jobB->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [$jobC->id],
        parallel_parents  => [],
    },
    $jobC->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [$jobE->id, $jobF->id],
        parallel_parents  => [$jobB->id],
    },
    $jobD->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [$jobE->id],
        parallel_parents  => [$jobA->id],
    },
    $jobE->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [],
        parallel_parents  => [$jobC->id, $jobD->id],
    },
    $jobF->id => {
        chained_children  => [],
        chained_parents   => [],
        parallel_children => [],
        parallel_parents  => [$jobC->id],
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
is($result, 'incomplete', 'job_set_done');
$result = $jobE->done(result => 'incomplete');
is($result, 'incomplete', 'job_set_done');

my $job = job_get_deps($jobA->id);
is($job->{state},  "done",   "job_set_done changed state");
is($job->{result}, "failed", "job_set_done changed result");

$job = job_get_deps($jobB->id);
is($job->{state}, "running", "job_set_done changed state");

$job = job_get_deps($jobC->id);
is($job->{state}, "running", "job_set_done changed state");

$job = job_get_deps($jobD->id);
is($job->{state},  "done",            "job_set_done changed state");
is($job->{result}, "parallel_failed", "job_set_done changed result, jobD failed because of jobA");

$job = job_get_deps($jobE->id);
is($job->{state},  "done",            "job_set_done changed state");
is($job->{result}, "parallel_failed", "job_set_done changed result, jobE failed because of jobD");

$jobF->discard_changes;
$job = job_get_deps($jobF->id);
is($job->{state}, "running", "job_set_done changed state");

# check MM API for children status - available only for running jobs
my $worker = $schema->resultset("Workers")->find($worker_ids[1]);
my $t      = Test::Mojo->new('OpenQA::WebAPI');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $worker->get_property('JOBTOKEN'));
    });
$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

# duplicate jobF, the full cluster is duplicated too
my $id = $jobF->auto_duplicate;
ok(defined $id, "duplicate works");

$job = job_get_deps($jobA->id);    # cloned
is($job->{state},  "done",   "no change");
is($job->{result}, "failed", "no change");
ok(defined $job->{clone_id}, "cloned");

$job = job_get_deps($jobB->id);    # cloned
is($job->{result}, "parallel_failed", "$job->{id} B stopped");
ok(defined $job->{clone_id}, "cloned");
my $jobB2 = $job->{clone_id};

$job = job_get_deps($jobC->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobC2 = $job->{clone_id};

$job = job_get_deps($jobD->id);    # cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");

$job = job_get_deps($jobE->id);    # cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");

$job = job_get_deps($jobF->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobF2 = $job->{clone_id};

$job = job_get_deps($jobB2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");

$job = job_get_deps($jobC2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [$jobB2], Chained => []}, "cloned deps");

$job = job_get_deps($jobF2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [$jobC2], Chained => []}, "cloned deps");

# recheck that cloning didn't change MM API results children status
$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

$job = job_get_deps($jobA->id);    # cloned
is($job->{state},  "done",   "no change");
is($job->{result}, "failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobA2 = $job->{clone_id};

$job = job_get_deps($jobB->id);    # unchanged
is($job->{result},   "parallel_failed", "B is unchanged");
is($job->{clone_id}, $jobB2,            "cloned");

$job = job_get_deps($jobC->id);    # unchanged
is($job->{state},    "running",         "no change");
is($job->{result},   "parallel_failed", "C is restarted");
is($job->{clone_id}, $jobC2,            "cloned");

$job = job_get_deps($jobD->id);    #cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobD2 = $job->{clone_id};

$job = job_get_deps($jobE->id);    #cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobE2 = $job->{clone_id};

$job = job_get_deps($jobF->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobF2,    "cloned");

$job = job_get_deps($jobA2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [], Chained => []}, "cloned deps");

$job = job_get_deps($jobB2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [], Chained => []}, "cloned deps");

$job = job_get_deps($jobC2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [$jobB2], Chained => []}, "cloned deps");


$job = job_get_deps($jobD2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [$jobA2], Chained => []}, "cloned deps");

$job = job_get_deps($jobE2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply([sort @{$job->{parents}->{Parallel}}], [sort ($jobC2, $jobD2)], "cloned deps");

$job = job_get_deps($jobF2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, {Parallel => [$jobC2], Chained => []}, "cloned deps");

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

# job_grab now should return jobs from clonned group
# we already called job_set_done on jobE, so worker 6 is available
$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $worker_ids[5], allocate => 1);
is($job->{id},                  $jobB2, "jobB2");            #lowest prio of jobs without parents
is($job->{settings}->{NICVLAN}, 2,      "different vlan");


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

is_deeply($jobY->to_hash(deps => 1)->{parents}, {Chained => [$jobX->id], Parallel => []}, "JobY parents fit");
# when Y is scheduled and X is duplicated, Y must be cancelled and Y2 needs to depend on X2
my $jobX2 = $jobX->auto_duplicate;
$jobY->discard_changes;
is($jobY->state, "skipped", "jobY was skipped");
my $jobY2 = $jobY->clone;
ok(defined $jobY2, "jobY was cloned too");
is_deeply($jobY2->to_hash(deps => 1)->{parents}, {Chained => [$jobX2->id], Parallel => []}, "JobY parents fit");
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
is_deeply($jobY3->{parents}, {Chained => [$jobX3->id], Parallel => []}, 'jobY3 parent is now jobX3');

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
_jobs_update_state([$jobH, $jobJ, $jobK, $jobL], OpenQA::Jobs::Constants::RUNNING);

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
# original state:
# Q <- (chained) W <-\ (parallel)
#   ^- (chained) U <-- (parallel) T
#   ^- (chained) R <-/ (parallel) | (chained)
#   ^-----------------------------/
#
# Q is done; W,U,R and T is running

my %settingsQ = (%settings, TEST => 'Q');
my %settingsW = (%settings, TEST => 'W');
my %settingsU = (%settings, TEST => 'U');
my %settingsR = (%settings, TEST => 'R');
my %settingsT = (%settings, TEST => 'T');

my $jobQ = _job_create(\%settingsQ);
my $jobW = _job_create(\%settingsW, undef, [$jobQ->id]);
my $jobU = _job_create(\%settingsU, undef, [$jobQ->id]);
my $jobR = _job_create(\%settingsR, undef, [$jobQ->id]);
my $jobT = _job_create(\%settingsT, [$jobW->id, $jobU->id, $jobR->id], [$jobQ->id]);

is($jobW->blocked_by_id, $jobQ->id, "JobW is blocked");

# hack jobs to appear to scheduler in desired state
_jobs_update_state([$jobQ], OpenQA::Jobs::Constants::DONE);
_jobs_update_state([$jobW, $jobU, $jobR, $jobT], OpenQA::Jobs::Constants::RUNNING);

# duplicate U
my $jobU2 = $jobU->auto_duplicate;

# expected state:
# Q <- (chained) W2 <-\ (parallel)
#   ^- (chained) E2 <-- (parallel) T2
#   ^- (chained) R2 <-/ (parallel) | (chained)
#   ^------------------------------/
#
# Q is done; W2,E2,R2 and T2 are scheduled

ok($jobU2, 'jobU duplicated');
# reload data from DB
$_->discard_changes for ($jobQ, $jobW, $jobU, $jobR, $jobT);
# check other clones
ok(!$jobQ->clone, 'jobQ not cloned');
ok($jobW->clone,  'jobW cloned');
ok($jobU->clone,  'jobU cloned');
ok($jobR->clone,  'jobR cloned');
ok($jobT->clone,  'jobT cloned');

$jobQ = job_get_deps($jobQ->id);
my $jobW2 = job_get_deps($jobW->clone->id);
my $jobR2 = job_get_deps($jobR->clone->id);
my $jobT2 = job_get_deps($jobT->clone->id);

my @sorted_got = sort(@{$jobQ->{children}->{Chained}});
my @sorted_exp
  = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}, $jobT2->{id}, $jobW->id, $jobU->id, $jobR->id, $jobT->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is chained parent to all jobs');

@sorted_got = sort(@{$jobT2->{parents}->{Parallel}});
@sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}));
is_deeply(\@sorted_got, \@sorted_exp, 'jobT is parallel child of all jobs except jobQ');

is_deeply($jobW2->{children}, {Chained => [], Parallel => [$jobT2->{id}]}, 'jobW2 has no child dependency to sibling');
is_deeply(
    $jobU2->to_hash(deps => 1)->{children},
    {Chained => [], Parallel => [$jobT2->{id}]},
    'jobU2 has no child dependency to sibling'
);
is_deeply($jobR2->{children}, {Chained => [], Parallel => [$jobT2->{id}]}, 'jobR2 has no child dependency to sibling');

is_deeply($jobW2->{parents}, {Chained => [$jobQ->{id}], Parallel => []}, 'jobW2 has no parent dependency to sibling');
is_deeply(
    $jobU2->to_hash(deps => 1)->{parents},
    {Chained => [$jobQ->{id}], Parallel => []},
    'jobU2 has no parent dependency to sibling'
);
is_deeply($jobR2->{parents}, {Chained => [$jobQ->{id}], Parallel => []}, 'jobR2 has no parent dependency to sibling');

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
_jobs_update_state([$jobP, $jobO, $jobI], OpenQA::Jobs::Constants::DONE);

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
_jobs_update_state([$jobP2], OpenQA::Jobs::Constants::RUNNING);
_jobs_update_state([$jobO2], OpenQA::Jobs::Constants::DONE);
_jobs_update_state([$jobI2], OpenQA::Jobs::Constants::DONE);

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
_jobs_update_state([$jobA, $jobB, $jobC, $jobD], OpenQA::Jobs::Constants::DONE, OpenQA::Jobs::Constants::PASSED);

# only job B failed as incomplete
$jobB->result(OpenQA::Jobs::Constants::INCOMPLETE);
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
$jobB->clone->state(OpenQA::Jobs::Constants::RUNNING);
$jobB->clone->update;

# clone A
$jobA->discard_changes;
ok(!$jobA->clone, "jobA not yet cloned");
$jobA2 = $jobA->auto_duplicate;
ok($jobA2, 'jobA duplicated');
$jobA->discard_changes;

$jobA->clone->state(OpenQA::Jobs::Constants::RUNNING);
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
my @deps = sort { $a <=> $b } ($jobB2_h->{id}, $jobC2_h->{id}, $jobD2_h->{id});
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
_jobs_update_state([$jobA], OpenQA::Jobs::Constants::DONE, OpenQA::Jobs::Constants::PASSED);
_jobs_update_state([$jobB, $jobC, $jobD], OpenQA::Jobs::Constants::RUNNING);

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
$jobA2->state(OpenQA::Jobs::Constants::RUNNING);
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
    _jobs_update_state([$jobA], OpenQA::Jobs::Constants::DONE, OpenQA::Jobs::Constants::PASSED);
    _jobs_update_state([$jobB, $jobC, $jobD], OpenQA::Jobs::Constants::DONE, OpenQA::Jobs::Constants::FAILED);

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
    _jobs_update_state([$job], $state, OpenQA::Jobs::Constants::PASSED);
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
    my $jobSUS = _job_create_set_done(\%settingsSUS, OpenQA::Jobs::Constants::DONE);
    # Admin Server 1
    $settingsAS{_PARALLEL_JOBS} = [$jobSUS->id];
    my $jobAS = _job_create_set_done(\%settingsAS, OpenQA::Jobs::Constants::DONE);
    # Image server 2
    $settingsIS2{_START_AFTER_JOBS} = [$jobAS->id];
    my $jobIS2 = _job_create_set_done(\%settingsIS2, OpenQA::Jobs::Constants::DONE);
    # Image server
    $settingsIS{_PARALLEL_JOBS}    = [$jobSUS->id];
    $settingsIS{_START_AFTER_JOBS} = [$jobAS->id];
    my $jobIS = _job_create_set_done(\%settingsIS, OpenQA::Jobs::Constants::CANCELLED);
    # Branch server
    $settingsBS{_PARALLEL_JOBS} = [$jobAS->id, $jobSUS->id];
    my $jobBS = _job_create_set_done(\%settingsBS, OpenQA::Jobs::Constants::DONE);
    # Terminal
    $settingsT{_PARALLEL_JOBS} = [$jobBS->id];
    my $jobT = _job_create_set_done(\%settingsT, OpenQA::Jobs::Constants::DONE);
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

done_testing();
