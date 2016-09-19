#!/usr/bin/env perl -w

# Copyright (C) 2014-2016 SUSE LLC
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
}

use strict;
use Data::Dump qw/pp dd/;
use OpenQA::Scheduler::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Test::Mojo;
use Test::More;
use Test::Warnings;

my $schema = OpenQA::Test::Database->new->create();

# create Test DBus bus and service for fake WebSockets call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws = OpenQA::WebSockets->new;

#my $t = Test::Mojo->new('OpenQA::WebAPI');

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
    my $job = $schema->resultset("Jobs")->search({'me.id' => $id}, {prefetch => ['settings', 'parents', 'children']})->first;
    return $job;
}

sub job_get_deps {
    return job_get_deps_rs(@_)->to_hash(deps => 1);
}

my $current_jobs = list_jobs();
#diag explain $current_jobs;

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

my $workercaps = {};
$workercaps->{cpu_modelname} = 'Rainbow CPU';
$workercaps->{cpu_arch}      = 'x86_64';
$workercaps->{cpu_opmode}    = '32-bit, 64-bit';
$workercaps->{mem_max}       = '4096';



# parallel dependencies
#
# A <--- D <--- E
#              /
# B <--- C <--/
#        ^
#        \--- F

my %settingsA = %settings;
my %settingsB = %settings;
my %settingsC = %settings;
my %settingsD = %settings;
my %settingsE = %settings;
my %settingsF = %settings;

$settingsA{TEST} = 'A';
$settingsB{TEST} = 'B';
$settingsC{TEST} = 'C';
$settingsD{TEST} = 'D';
$settingsE{TEST} = 'E';
$settingsF{TEST} = 'F';

sub _job_create {
    my $job = $schema->resultset('Jobs')->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

my $jobA = _job_create(\%settingsA);

my $jobB = _job_create(\%settingsB);

$settingsC{_PARALLEL_JOBS} = [$jobB->id];
my $jobC = _job_create(\%settingsC);

$settingsD{_PARALLEL_JOBS} = [$jobA->id];
my $jobD = _job_create(\%settingsD);

$settingsE{_PARALLEL_JOBS} = $jobC->id . ',' . $jobD->id;    # test also IDs passed as comma separated string
my $jobE = _job_create(\%settingsE);

$settingsF{_PARALLEL_JOBS} = [$jobC->id];
my $jobF = _job_create(\%settingsF);

$jobA->set_prio(3);
$jobB->set_prio(2);
$jobC->set_prio(4);
$jobD->set_prio(1);
$jobE->set_prio(1);
$jobF->set_prio(1);

#diag "jobA ", $jobA;
#diag "jobB ", $jobB;
#diag "jobC ", $jobC;
#diag "jobD ", $jobD;
#diag "jobE ", $jobE;
#diag "jobF ", $jobF;

use OpenQA::WebAPI::Controller::API::V1::Worker;
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;

my $w1_id = $c->_register($schema, "host", "1", $workercaps);
my $w2_id = $c->_register($schema, "host", "2", $workercaps);
my $w3_id = $c->_register($schema, "host", "3", $workercaps);
my $w4_id = $c->_register($schema, "host", "4", $workercaps);
my $w5_id = $c->_register($schema, "host", "5", $workercaps);
my $w6_id = $c->_register($schema, "host", "6", $workercaps);

#websocket
#my $ws1 = $t->websocket_ok("/api/v1/workers/$w1_id/ws");
#my $ws2 = $t->websocket_ok("/api/v1/workers/$w2_id/ws");
#my $ws3 = $t->websocket_ok("/api/v1/workers/$w3_id/ws");
#my $ws4 = $t->websocket_ok("/api/v1/workers/$w4_id/ws");
#my $ws5 = $t->websocket_ok("/api/v1/workers/$w5_id/ws");
#my $ws6 = $t->websocket_ok("/api/v1/workers/$w6_id/ws");

my $job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w1_id);
is($job->{id},                  $jobB->id, "jobB");                   #lowest prio of jobs without parents
is($job->{settings}->{NICVLAN}, 1,         "first available vlan");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w2_id);
is($job->{id},                  $jobC->id, "jobC");                        #direct child of B
is($job->{settings}->{NICVLAN}, 1,         "same vlan for whole group");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w3_id);
is($job->{id},                  $jobF->id, "jobF");                        #direct child of C
is($job->{settings}->{NICVLAN}, 1,         "same vlan for whole group");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w4_id);
is($job->{id},                  $jobA->id, "jobA");                        # E is direct child of C, but A and D must be started first
is($job->{settings}->{NICVLAN}, 1,         "same vlan for whole group");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w5_id);
is($job->{id},                  $jobD->id, "jobD");                        # direct child of A
is($job->{settings}->{NICVLAN}, 1,         "same vlan for whole group");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w6_id);
is($job->{id},                  $jobE->id, "jobE");                        # C and D are now running so we can start E
is($job->{settings}->{NICVLAN}, 1,         "same vlan for whole group");

# jobA failed
my $result = $jobA->done(result => 'failed');
is($result, 'failed', 'job_set_done');

# then jobD and jobE, workers 5 and 6 must be canceled
#$ws5->message_ok;
#$ws5->message_is('cancel');

#$ws6->message_ok;
#$ws6->message_is('cancel');

# reload changes from DB - jobs should be cancelled by failed jobA
$jobD->discard_changes;
$jobE->discard_changes;
# this should not change the result which is parallel_failed due to failed jobA
$result = $jobD->done(result => 'incomplete');
is($result, 'incomplete', 'job_set_done');
$result = $jobE->done(result => 'incomplete');
is($result, 'incomplete', 'job_set_done');

$job = job_get_deps($jobA->id);
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
my $worker = $schema->resultset("Workers")->find($w2_id);

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $worker->get_property('JOBTOKEN'));
    });

$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

# duplicate jobF, parents are duplicated too
my $id = $jobF->auto_duplicate;
ok(defined $id, "duplicate works");

$job = job_get_deps($jobA->id);    #unchanged
is($job->{state},    "done",   "no change");
is($job->{result},   "failed", "no change");
is($job->{clone_id}, undef,    "no clones");

$job = job_get_deps($jobB->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobB2 = $job->{clone_id};


$job = job_get_deps($jobC->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobC2 = $job->{clone_id};

$job = job_get_deps($jobD->id);    #unchanged
is($job->{state},    "done",            "no change");
is($job->{result},   "parallel_failed", "no change");
is($job->{clone_id}, undef,             "no clones");

$job = job_get_deps($jobE->id);    #unchanged
is($job->{state},    "done",            "no change");
is($job->{result},   "parallel_failed", "no change");
is($job->{clone_id}, undef,             "no clones");

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

# now we have
#
# A <--- D <--- E
# done   done   done
#              /
# B <--- C <--/
# run    run
#        ^
#        \--- F
#             run
#
# B2 <--- C2 <--- F2
# sch     sch     sch

# now duplicate jobE, parents A, D have to be duplicated,
# C2 is scheduled so it can be used as parent of E2 without duplicating
$id = $jobE->auto_duplicate;
ok(defined $id, "duplicate works");

$job = job_get_deps($jobA->id);    #cloned
is($job->{state},  "done",   "no change");
is($job->{result}, "failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobA2 = $job->{clone_id};

$job = job_get_deps($jobB->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobB2,    "cloned");


$job = job_get_deps($jobC->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobC2,    "cloned");

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

# now we have
#
# A <--- D <--- E
# done   done   done
#              /
# B <--- C <--/
# run    run
#        ^
#        \--- F
#             run
#
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
$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w6_id);
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

# current state
#
# X <---- Y
# done    sch.

# when Y is scheduled and X is duplicated, Y must be rerouted to depend on X now
my $jobX2 = $jobX->auto_duplicate;
$jobY->discard_changes;
is($jobX2->id,    $jobY->parents->single->parent_job_id, 'jobY parent is now jobX clone');
is($jobX2->clone, undef,                                 "no clone");
is($jobY->clone,  undef,                                 "no clone");

# current state:
#
# X
# done
#
# X2 <---- Y
# sch.    sch.

ok($jobX2->done(result => 'passed'), 'jobX2 set to done');
ok($jobY->done(result => 'passed'), 'jobY set to done');

# current state:
#
# X
# done
#
# X2 <---- Y
# done    done

my $jobY2 = $jobY->auto_duplicate;

# current state:
#
# X
# done
#
#       /-- Y done
#    <-/
# X2 <---- Y2
# done    sch.

is_deeply($jobY2->to_hash(deps => 1)->{parents}, {Chained => [$jobX2->id], Parallel => []}, 'jobY2 parent is now jobX2');
is($jobX2->{clone_id}, undef, "X no clone");
is($jobY2->clone_id,   undef, "Y no clone");

ok($jobY2->done(result => 'passed'), 'jobY2 set to done');

# current state:
#
# X
# done
#
#       /-- Y done
#    <-/
# X2 <---- Y2
# done    done


my $jobX3 = $jobX2->auto_duplicate;

# current state:
#
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
#
# H <-(parallel) J
# ^             ^
# | (parallel)  | (parallel)
# K             L
my %settingsH = %settings;
my %settingsJ = %settings;
my %settingsK = %settings;
my %settingsL = %settings;

$settingsH{TEST} = 'H';
$settingsJ{TEST} = 'J';
$settingsK{TEST} = 'K';
$settingsL{TEST} = 'L';

my $jobH = _job_create(\%settingsH);

$settingsK{_PARALLEL_JOBS} = [$jobH->id];
my $jobK = _job_create(\%settingsK);

$settingsJ{_PARALLEL_JOBS} = [$jobH->id];
my $jobJ = _job_create(\%settingsJ);

$settingsL{_PARALLEL_JOBS} = [$jobJ->id];
my $jobL = _job_create(\%settingsL);

# hack jobs to appear running to scheduler
$jobH->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobH->update;
$jobJ->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobJ->update;
$jobK->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobK->update;
$jobL->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobL->update;

# expected output after cloning D, all jobs scheduled
# H2 <-(parallel) J2
# ^              ^
# | (parallel)   | (parallel)
# K2             L2

my $jobL2 = $jobL->auto_duplicate;
ok($jobL2, 'jobL duplicated');
# reload data from DB
$jobH->discard_changes;
$jobK->discard_changes;
$jobJ->discard_changes;
$jobL->discard_changes;
# check other clones
ok($jobJ->clone, 'jobJ cloned');
ok($jobH->clone, 'jobH cloned');
ok($jobK->clone, 'jobK cloned');

my $jobJ2 = $jobL2->to_hash(deps => 1)->{parents}->{Parallel}->[0];
is($jobJ2, $jobJ->clone->id, 'J2 cloned with parallel parent dep');
my $jobH2 = job_get_deps($jobJ2)->{parents}->{Parallel}->[0];
is($jobH2, $jobH->clone->id, 'H2 cloned with parallel parent dep');
my $jobK2 = job_get_deps($jobH2)->{children}->{Parallel}->[0];
is($jobK2, $jobK->clone->id, 'K2 cloned with parallel children dep');

# checking all-in mixed scenario

# original state
#
# Q <- (chained) W <-\ (parallel)
#   ^- (chained) U <-- (parallel) T
#   ^- (chained) R <-/ (parallel) | (chained)
#   ^-----------------------------/
#
# Q is done; W,U,R and T is running

my %settingsQ = %settings;
my %settingsW = %settings;
my %settingsU = %settings;
my %settingsR = %settings;
my %settingsT = %settings;

$settingsQ{TEST} = 'Q';
$settingsW{TEST} = 'W';
$settingsU{TEST} = 'U';
$settingsR{TEST} = 'R';
$settingsT{TEST} = 'T';

my $jobQ = _job_create(\%settingsQ);

$settingsW{_START_AFTER_JOBS} = [$jobQ->id];
my $jobW = _job_create(\%settingsW);
$settingsU{_START_AFTER_JOBS} = [$jobQ->id];
my $jobU = _job_create(\%settingsU);
$settingsR{_START_AFTER_JOBS} = [$jobQ->id];
my $jobR = _job_create(\%settingsR);

$settingsT{_PARALLEL_JOBS} = [$jobW->id, $jobU->id, $jobR->id];
$settingsT{_START_AFTER_JOBS} = [$jobQ->id];
my $jobT = _job_create(\%settingsT);

# hack jobs to appear to scheduler in desired state
$jobQ->state(OpenQA::Schema::Result::Jobs::DONE);
$jobQ->update;
$jobW->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobW->update;
$jobU->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobU->update;
$jobR->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobR->update;
$jobT->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobT->update;

# duplicate U
my $jobU2 = $jobU->auto_duplicate;

# expected state
#
# Q <- (chained) W2 <-\ (parallel)
#   ^- (chained) E2 <-- (parallel) T2
#   ^- (chained) R2 <-/ (parallel) | (chained)
#   ^------------------------------/
#
# Q is done; W2,E2,R2 and T2 are scheduled

ok($jobU2, 'jobU duplicated');
# reload data from DB
$jobQ->discard_changes;
$jobW->discard_changes;
$jobU->discard_changes;
$jobR->discard_changes;
$jobT->discard_changes;
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
my @sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}, $jobT2->{id}, $jobW->id, $jobU->id, $jobR->id, $jobT->id));
is_deeply(\@sorted_got, \@sorted_exp, 'jobQ is chained parent to all jobs');

@sorted_got = sort(@{$jobT2->{parents}->{Parallel}});
@sorted_exp = sort(($jobW2->{id}, $jobU2->id, $jobR2->{id}));
is_deeply(\@sorted_got, \@sorted_exp, 'jobT is parallel child of all jobs except jobQ');

is_deeply($jobW2->{children}, {Chained => [], Parallel => [$jobT2->{id}]}, 'jobW2 has no child dependency to sibling');
is_deeply($jobU2->to_hash(deps => 1)->{children}, {Chained => [], Parallel => [$jobT2->{id}]}, 'jobU2 has no child dependency to sibling');
is_deeply($jobR2->{children}, {Chained => [], Parallel => [$jobT2->{id}]}, 'jobR2 has no child dependency to sibling');

is_deeply($jobW2->{parents}, {Chained => [$jobQ->{id}], Parallel => []}, 'jobW2 has no parent dependency to sibling');
is_deeply($jobU2->to_hash(deps => 1)->{parents}, {Chained => [$jobQ->{id}], Parallel => []}, 'jobU2 has no parent dependency to sibling');
is_deeply($jobR2->{parents}, {Chained => [$jobQ->{id}], Parallel => []}, 'jobR2 has no parent dependency to sibling');

# check cloning of clones
# this is to check whether duplication propely travers clones to find latest clone
# test is divided into two parts, cloning jobO and then jobI

# original state, all jobs DONE
#
# P <-(parallel) O <-(parallel) I
#
my %settingsP = %settings;
my %settingsO = %settings;
my %settingsI = %settings;

$settingsP{TEST} = 'P';
$settingsO{TEST} = 'O';
$settingsI{TEST} = 'I';

my $jobP = _job_create(\%settingsP);

$settingsO{_PARALLEL_JOBS} = [$jobP->id];
my $jobO = _job_create(\%settingsO);
$settingsI{_PARALLEL_JOBS} = [$jobO->id];
my $jobI = _job_create(\%settingsI);

# hack jobs to appear to scheduler in desired state
$jobP->state(OpenQA::Schema::Result::Jobs::DONE);
$jobP->update;
$jobO->state(OpenQA::Schema::Result::Jobs::DONE);
$jobO->update;
$jobI->state(OpenQA::Schema::Result::Jobs::DONE);
$jobI->update;

#
# cloning O gets to expected state
#
# P2 <-(parallel) O2 (clone of) O <-(parallel) I
#
my $jobO2 = $jobO->auto_duplicate;
ok($jobO2, 'jobO duplicated');
# reload data from DB
$jobP->discard_changes;
$jobO->discard_changes;
$jobI->discard_changes;
# check other clones
ok($jobP->clone,  'jobP cloned');
ok($jobO->clone,  'jobO cloned');
ok(!$jobI->clone, 'jobI not cloned');

$jobO2 = job_get_deps($jobO2->id);
$jobI  = job_get_deps($jobI->id);
my $jobP2 = job_get_deps($jobP->clone->id);

is_deeply($jobI->{parents}->{Parallel},  [$jobO->id],    'jobI retain its original parent');
is_deeply($jobO2->{parents}->{Parallel}, [$jobP2->{id}], 'clone jobO2 gets new parent jobP2');

# get Jobs RS from ids for cloned jobs
$jobO2 = $schema->resultset('Jobs')->search({id => $jobO2->{id}})->single;
$jobP2 = $schema->resultset('Jobs')->search({id => $jobP2->{id}})->single;
# set P2 running and O2 done
$jobP2->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobP2->update;
$jobO2->state(OpenQA::Schema::Result::Jobs::DONE);
$jobO2->update;

#
# cloning I gets to expected state
#
# P3 <-(parallel) O3 <-(parallel) I2
#
my $jobI2 = job_get($jobI->{id})->auto_duplicate;
ok($jobI2, 'jobI duplicated');

# reload data from DB
$jobP2->discard_changes;
$jobO2->discard_changes;

ok($jobP2->clone, 'jobP2 cloned');
ok($jobO2->clone, 'jobO2 cloned');

$jobI2 = job_get_deps($jobI2->id);
my $jobO3 = job_get_deps($jobO2->clone->id);
my $jobP3 = job_get_deps($jobP2->clone->id);

is_deeply($jobI2->{parents}->{Parallel}, [$jobO3->{id}], 'jobI2 got new parent jobO3');
is_deeply($jobO3->{parents}->{Parallel}, [$jobP3->{id}], 'clone jobO3 gets new parent jobP3');

# https://progress.opensuse.org/issues/10456

%settingsA = %settings;
%settingsB = %settings;
%settingsC = %settings;
%settingsD = %settings;

$settingsA{TEST} = '116539';
$settingsB{TEST} = '116569';
$settingsC{TEST} = '116570';
$settingsD{TEST} = '116571';

$jobA                         = _job_create(\%settingsA);
$settingsB{_START_AFTER_JOBS} = [$jobA->id];
$jobB                         = _job_create(\%settingsB);
$settingsC{_START_AFTER_JOBS} = [$jobA->id];
$jobC                         = _job_create(\%settingsC);
$settingsD{_START_AFTER_JOBS} = [$jobA->id];
$jobD                         = _job_create(\%settingsD);

# hack jobs to appear done to scheduler
for ($jobA, $jobB, $jobC, $jobD) {
    $_->state(OpenQA::Schema::Result::Jobs::DONE);
    $_->result(OpenQA::Schema::Result::Jobs::PASSED);
    $_->update;
}

# only job B failed as incomplete
$jobB->result(OpenQA::Schema::Result::Jobs::INCOMPLETE);
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


use Data::Dump qw/pp/;
# expected situation
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
$jobB->clone->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobB->clone->update;

# clone A
$jobA2 = $jobA->auto_duplicate;
ok($jobA2, 'jobA duplicated');
$jobA->discard_changes;

$jobA->clone->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobA->clone->update;
$jobA2 = $jobA->clone->auto_duplicate;
ok($jobA2, 'jobA->clone duplicated');

# update local copy from DB
$_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

# expected situation, all chained:

# A2 <- B2 (clone of Bc)
#    |- C2
#    \- D2
ok($jobB->clone->clone, 'jobB clone jobBc was cloned');
my $jobB2_h = job_get_deps($jobB->clone->clone->id);
is_deeply($jobB2_h->{parents}->{Chained}, [$jobA2->id], 'jobB2 has jobA2 as chained parent');
is($jobB2_h->{settings}{TEST}, $jobB->TEST, 'jobB2 test and jobB test are equal');

ok($jobC->clone, 'jobC was cloned');
my $jobC2_h = job_get_deps($jobC->clone->id);
is_deeply($jobC2_h->{parents}->{Chained}, [$jobA2->id], 'jobC2 has jobA2 as chained parent');
is($jobC2_h->{settings}{TEST}, $jobC->TEST, 'jobC2 test and jobC test are equal');

ok($jobD->clone, 'jobD was cloned');
my $jobD2_h = job_get_deps($jobD->clone->id);
is_deeply($jobD2_h->{parents}->{Chained}, [$jobA2->id], 'jobD2 has jobA2 as chained parent');
is($jobD2_h->{settings}{TEST}, $jobD->TEST, 'jobD2 test and jobD test are equal');

my $jobA2_h = job_get_deps($jobA2->id);
is_deeply($jobA2_h->{children}->{Chained}, [$jobB2_h->{id}, $jobC2_h->{id}, $jobD2_h->{id}], 'jobA2 has jobB2, jobC2 and jobD2 as children');

# situation parent is done, children running -> parent is cloned -> parent is running -> parent is cloned. Check all children has new parent
# A <- B
#   |- C
#   \- D
%settingsA = %settings;
%settingsB = %settings;
%settingsC = %settings;
%settingsD = %settings;

$settingsA{TEST} = '116539A';
$settingsB{TEST} = '116569A';
$settingsC{TEST} = '116570A';
$settingsD{TEST} = '116571A';

$jobA                         = _job_create(\%settingsA);
$settingsB{_START_AFTER_JOBS} = [$jobA->id];
$jobB                         = _job_create(\%settingsB);
$settingsC{_START_AFTER_JOBS} = [$jobA->id];
$jobC                         = _job_create(\%settingsC);
$settingsD{_START_AFTER_JOBS} = [$jobA->id];
$jobD                         = _job_create(\%settingsD);

# hack jobs to appear done to scheduler
$jobA->state(OpenQA::Schema::Result::Jobs::DONE);
$jobA->result(OpenQA::Schema::Result::Jobs::PASSED);
$jobA->update;
for ($jobB, $jobC, $jobD) {
    $_->state(OpenQA::Schema::Result::Jobs::RUNNING);
    $_->update;
}

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
$jobA2->state(OpenQA::Schema::Result::Jobs::RUNNING);
$jobA2->update;
my $jobA3 = $jobA2->auto_duplicate;
$_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

# check all children were cloned anymore and has $jobA3 as parent
for ($jobB, $jobC, $jobD) {
    ok(!$_->clone->clone, 'job correctly not cloned');
    my $h = job_get_deps($_->clone->id);
    is_deeply($h->{parents}{Chained}, [$jobA3->id], 'job has jobA3 as parent');
}

# situation: chanied parent is done, children are all failed and has parallel dependency to the first sibling
#    /- C
#    |  |
# A <-- B
#    |  |
#    \- D
%settingsA = %settings;
%settingsB = %settings;
%settingsC = %settings;
%settingsD = %settings;

$settingsA{TEST} = '360-A';
$settingsB{TEST} = '360-B';
$settingsC{TEST} = '360-C';
$settingsD{TEST} = '360-D';

$jobA                         = _job_create(\%settingsA);
$settingsB{_START_AFTER_JOBS} = [$jobA->id];
$jobB                         = _job_create(\%settingsB);
$settingsC{_START_AFTER_JOBS} = [$jobA->id];
$settingsC{_PARALLEL_JOBS}    = [$jobB->id];
$jobC                         = _job_create(\%settingsC);
$settingsD{_START_AFTER_JOBS} = [$jobA->id];
$settingsD{_PARALLEL_JOBS}    = [$jobB->id];
$jobD                         = _job_create(\%settingsD);

# hack jobs to appear done to scheduler
$jobA->state(OpenQA::Schema::Result::Jobs::DONE);
$jobA->result(OpenQA::Schema::Result::Jobs::PASSED);
$jobA->update;
for ($jobB, $jobC, $jobD) {
    $_->state(OpenQA::Schema::Result::Jobs::DONE);
    $_->result(OpenQA::Schema::Result::Jobs::FAILED);
    $_->update;
}

$jobA2 = $jobA->auto_duplicate;
$_->discard_changes for ($jobA, $jobB, $jobC, $jobD);

# check all children were cloned and has $jobA as parent
for ($jobB, $jobC, $jobD) {
    ok($_->clone, 'job cloned');
    my $h = job_get_deps($_->clone->id);
    is_deeply($h->{parents}{Chained}, [$jobA2->id], 'job has jobA2 as parent');
}

for ($jobC, $jobD) {
    my $h = job_get_deps($_->clone->id);
    is_deeply($h->{parents}{Parallel}, [$jobB->clone->id], 'job has jobB2 as parallel parent');
}

done_testing();
