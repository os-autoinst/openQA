#!/usr/bin/env perl -w

# Copyright (C) 2014 SUSE Linux Products GmbH
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
use OpenQA::Scheduler;
use OpenQA::Test::Database;
use Test::Mojo;
use Test::More tests => 87;

my $schema = OpenQA::Test::Database->new->create();

#my $t = Test::Mojo->new('OpenQA');

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } OpenQA::Scheduler::query_jobs(%args)->all];
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
    ARCH        => 'x86_64'
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

my $jobA = OpenQA::Scheduler::job_create(\%settingsA);

my $jobB = OpenQA::Scheduler::job_create(\%settingsB);

$settingsC{_PARALLEL_JOBS} = [$jobB->id];
my $jobC = OpenQA::Scheduler::job_create(\%settingsC);

$settingsD{_PARALLEL_JOBS} = [$jobA->id];
my $jobD = OpenQA::Scheduler::job_create(\%settingsD);

$settingsE{_PARALLEL_JOBS} = [$jobC->id, $jobD->id];
my $jobE = OpenQA::Scheduler::job_create(\%settingsE);

$settingsF{_PARALLEL_JOBS} = [$jobC->id];
my $jobF = OpenQA::Scheduler::job_create(\%settingsF);

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

use OpenQA::Controller::API::V1::Worker;
my $c = OpenQA::Controller::API::V1::Worker->new;

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

my $job = OpenQA::Scheduler::job_grab(workerid => $w1_id);
is($job->{id}, $jobB->id, "jobB");    #lowest prio of jobs without parents

$job = OpenQA::Scheduler::job_grab(workerid => $w2_id);
is($job->{id}, $jobC->id, "jobC");    #direct child of B

$job = OpenQA::Scheduler::job_grab(workerid => $w3_id);
is($job->{id}, $jobF->id, "jobF");    #direct child of C

$job = OpenQA::Scheduler::job_grab(workerid => $w4_id);
is($job->{id}, $jobA->id, "jobA");    # E is direct child of C, but A and D must be started first

$job = OpenQA::Scheduler::job_grab(workerid => $w5_id);
is($job->{id}, $jobD->id, "jobD");    # direct child of A

$job = OpenQA::Scheduler::job_grab(workerid => $w6_id);
is($job->{id}, $jobE->id, "jobE");    # C and D are now running so we can start E

# jobA failed
my $result = OpenQA::Scheduler::job_set_done(jobid => $jobA->id, result => 'failed');
ok($result, "job_set_done");

# then jobD and jobE, workers 5 and 6 must be canceled
#$ws5->message_ok;
#$ws5->message_is('cancel');

#$ws6->message_ok;
#$ws6->message_is('cancel');

$result = OpenQA::Scheduler::job_set_done(jobid => $jobD->id, result => 'incomplete');
ok($result, "job_set_done");

$result = OpenQA::Scheduler::job_set_done(jobid => $jobE->id, result => 'incomplete');
ok($result, "job_set_done");




$job = OpenQA::Scheduler::job_get($jobA->id);
is($job->{state},  "done",   "job_set_done changed state");
is($job->{result}, "failed", "job_set_done changed result");

$job = OpenQA::Scheduler::job_get($jobB->id);
is($job->{state}, "running", "job_set_done changed state");

$job = OpenQA::Scheduler::job_get($jobC->id);
is($job->{state}, "running", "job_set_done changed state");

$job = OpenQA::Scheduler::job_get($jobD->id);
is($job->{state},  "done",            "job_set_done changed state");
is($job->{result}, "parallel_failed", "job_set_done changed result, jobD failed because of jobA");

$job = OpenQA::Scheduler::job_get($jobE->id);
is($job->{state},  "done",            "job_set_done changed state");
is($job->{result}, "parallel_failed", "job_set_done changed result, jobE failed because of jobD");

$job = OpenQA::Scheduler::job_get($jobF->id);
is($job->{state}, "running", "job_set_done changed state");

# duplicate jobF, parents are duplicated too
my $id = OpenQA::Scheduler::job_duplicate(jobid => $jobF->id);
ok(defined $id, "duplicate works");

$job = OpenQA::Scheduler::job_get($jobA->id);    #unchanged
is($job->{state},    "done",   "no change");
is($job->{result},   "failed", "no change");
is($job->{clone_id}, undef,    "no clones");

$job = OpenQA::Scheduler::job_get($jobB->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobB2 = $job->{clone_id};


$job = OpenQA::Scheduler::job_get($jobC->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobC2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobD->id);    #unchanged
is($job->{state},    "done",            "no change");
is($job->{result},   "parallel_failed", "no change");
is($job->{clone_id}, undef,             "no clones");

$job = OpenQA::Scheduler::job_get($jobE->id);    #unchanged
is($job->{state},    "done",            "no change");
is($job->{result},   "parallel_failed", "no change");
is($job->{clone_id}, undef,             "no clones");

$job = OpenQA::Scheduler::job_get($jobF->id);    # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobF2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobB2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");

$job = OpenQA::Scheduler::job_get($jobC2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [$jobB2], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobF2);
is($job->{state},    "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [$jobC2], "cloned deps");


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
$id = OpenQA::Scheduler::job_duplicate(jobid => $jobE->id);
ok(defined $id, "duplicate works");

$job = OpenQA::Scheduler::job_get($jobA->id);    #cloned
is($job->{state},  "done",   "no change");
is($job->{result}, "failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobA2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobB->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobB2,    "cloned");


$job = OpenQA::Scheduler::job_get($jobC->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobC2,    "cloned");

$job = OpenQA::Scheduler::job_get($jobD->id);    #cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobD2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobE->id);    #cloned
is($job->{state},  "done",            "no change");
is($job->{result}, "parallel_failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobE2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobF->id);    # unchanged
is($job->{state},    "running", "no change");
is($job->{clone_id}, $jobF2,    "cloned");

$job = OpenQA::Scheduler::job_get($jobA2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobB2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobC2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [$jobB2], "cloned deps");


$job = OpenQA::Scheduler::job_get($jobD2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [$jobA2], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobE2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply([sort @{$job->{parents}}], [sort ($jobC2, $jobD2)], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobF2);
is($job->{state},    "scheduled", "no change");
is($job->{clone_id}, undef,       "no clones");
is_deeply($job->{parents}, [$jobC2], "cloned deps");

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

# check MM API for children status - available only for running jobs
my $worker = $schema->resultset("Workers")->find($w2_id);

my $t = Test::Mojo->new('OpenQA');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $worker->get_property('JOBTOKEN'));
    });

$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF->id]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE->id]);

## check CHAINED dependency cloning
my %settingsX = %settings;
$settingsX{TEST} = 'X';
my $jobX = OpenQA::Scheduler::job_create(\%settingsX);

my %settingsY = %settings;
$settingsY{TEST}              = 'Y';
$settingsY{_START_AFTER_JOBS} = [$jobX->id];
my $jobY = OpenQA::Scheduler::job_create(\%settingsY);

ok(job_set_done(jobid => $jobX->id, result => 'passed'), 'jobX set to done');
# since we are skipping job_grab, reload missing columns from DB
$jobX->discard_changes;
# when Y is scheduled and X is duplicated, Y must be rerouted to depend on X now
$job = OpenQA::Scheduler::job_duplicate(jobid => $jobX->id);
$jobY->discard_changes;
is($job, $jobY->parents->single->parent_job_id, 'jobY parent is now jobX clone');

done_testing();
