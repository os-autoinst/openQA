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
use Test::More tests => 85;

OpenQA::Test::Database->new->create();

#my $t = Test::Mojo->new('OpenQA');


my $current_jobs = list_jobs();
#diag explain $current_jobs;

my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE => "RainbowPC",
    ARCH => 'x86_64'
);

my $workercaps = {};
$workercaps->{cpu_modelname} = 'Rainbow CPU';
$workercaps->{cpu_arch} = 'x86_64';
$workercaps->{cpu_opmode} = '32-bit, 64-bit';
$workercaps->{mem_max} = '4096';



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

$settingsC{_PARALLEL_JOBS} = [$jobB];
my $jobC = OpenQA::Scheduler::job_create(\%settingsC);

$settingsD{_PARALLEL_JOBS} = [$jobA];
my $jobD = OpenQA::Scheduler::job_create(\%settingsD);

$settingsE{_PARALLEL_JOBS} = [$jobC, $jobD];
my $jobE = OpenQA::Scheduler::job_create(\%settingsE);

$settingsF{_PARALLEL_JOBS} = [$jobC];
my $jobF = OpenQA::Scheduler::job_create(\%settingsF);

OpenQA::Scheduler::job_set_prio(jobid => $jobA, prio => 3);
OpenQA::Scheduler::job_set_prio(jobid => $jobB, prio => 2);
OpenQA::Scheduler::job_set_prio(jobid => $jobC, prio => 4);
OpenQA::Scheduler::job_set_prio(jobid => $jobD, prio => 1);
OpenQA::Scheduler::job_set_prio(jobid => $jobE, prio => 1);
OpenQA::Scheduler::job_set_prio(jobid => $jobF, prio => 1);

#diag "jobA ", $jobA;
#diag "jobB ", $jobB;
#diag "jobC ", $jobC;
#diag "jobD ", $jobD;
#diag "jobE ", $jobE;
#diag "jobF ", $jobF;

my $w1_id = worker_register("host", "1", "backend", $workercaps);
my $w2_id = worker_register("host", "2", "backend", $workercaps);
my $w3_id = worker_register("host", "3", "backend", $workercaps);
my $w4_id = worker_register("host", "4", "backend", $workercaps);
my $w5_id = worker_register("host", "5", "backend", $workercaps);
my $w6_id = worker_register("host", "6", "backend", $workercaps);

#websocket
#my $ws1 = $t->websocket_ok("/api/v1/workers/$w1_id/ws");
#my $ws2 = $t->websocket_ok("/api/v1/workers/$w2_id/ws");
#my $ws3 = $t->websocket_ok("/api/v1/workers/$w3_id/ws");
#my $ws4 = $t->websocket_ok("/api/v1/workers/$w4_id/ws");
#my $ws5 = $t->websocket_ok("/api/v1/workers/$w5_id/ws");
#my $ws6 = $t->websocket_ok("/api/v1/workers/$w6_id/ws");

my $job = OpenQA::Scheduler::job_grab(workerid => $w1_id);
is($job->{id}, $jobB, "jobB"); #lowest prio of jobs without parents

$job = OpenQA::Scheduler::job_grab(workerid => $w2_id);
is($job->{id}, $jobC, "jobC"); #direct child of B

$job = OpenQA::Scheduler::job_grab(workerid => $w3_id);
is($job->{id}, $jobF, "jobF"); #direct child of C

$job = OpenQA::Scheduler::job_grab(workerid => $w4_id);
is($job->{id}, $jobA, "jobA"); # E is direct child of C, but A and D must be started first

$job = OpenQA::Scheduler::job_grab(workerid => $w5_id);
is($job->{id}, $jobD, "jobD"); # direct child of A

$job = OpenQA::Scheduler::job_grab(workerid => $w6_id);
is($job->{id}, $jobE, "jobE"); # C and D are now running so we can start E

# jobA failed
my $result = OpenQA::Scheduler::job_set_done(jobid => $jobA, result => 'failed');
ok($result, "job_set_done");

# then jobD and jobE, workers 5 and 6 must be canceled
#$ws5->message_ok;
#$ws5->message_is('cancel');

#$ws6->message_ok;
#$ws6->message_is('cancel');

$result = OpenQA::Scheduler::job_set_done(jobid => $jobD, result => 'incomplete');
ok($result, "job_set_done");

$result = OpenQA::Scheduler::job_set_done(jobid => $jobE, result => 'incomplete');
ok($result, "job_set_done");




$job = OpenQA::Scheduler::job_get($jobA);
is($job->{state}, "done", "job_set_done changed state");
is($job->{result}, "failed", "job_set_done changed result");

$job = OpenQA::Scheduler::job_get($jobB);
is($job->{state}, "running", "job_set_done changed state");

$job = OpenQA::Scheduler::job_get($jobC);
is($job->{state}, "running", "job_set_done changed state");

$job = OpenQA::Scheduler::job_get($jobD);
is($job->{state}, "done", "job_set_done changed state");
is($job->{result}, "incomplete", "job_set_done changed result");

$job = OpenQA::Scheduler::job_get($jobE);
is($job->{state}, "done", "job_set_done changed state");
is($job->{result}, "incomplete", "job_set_done changed result");

$job = OpenQA::Scheduler::job_get($jobF);
is($job->{state}, "running", "job_set_done changed state");

# duplicate jobF, parents are duplicated too
my $id = OpenQA::Scheduler::job_duplicate(jobid => $jobF);
ok(defined $id, "duplicate works");

$job = OpenQA::Scheduler::job_get($jobA); #unchanged
is($job->{state}, "done", "no change");
is($job->{result}, "failed", "no change");
is($job->{clone_id}, undef, "no clones");

$job = OpenQA::Scheduler::job_get($jobB); # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobB2 = $job->{clone_id};


$job = OpenQA::Scheduler::job_get($jobC); # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobC2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobD); #unchanged
is($job->{state}, "done", "no change");
is($job->{result}, "incomplete", "no change");
is($job->{clone_id}, undef, "no clones");

$job = OpenQA::Scheduler::job_get($jobE); #unchanged
is($job->{state}, "done", "no change");
is($job->{result}, "incomplete", "no change");
is($job->{clone_id}, undef, "no clones");

$job = OpenQA::Scheduler::job_get($jobF); # cloned
is($job->{state}, "running", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobF2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobB2);
is($job->{state}, "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef, "no clones");

$job = OpenQA::Scheduler::job_get($jobC2);
is($job->{state}, "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef, "no clones");
is_deeply($job->{parents}, [$jobB2], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobF2);
is($job->{state}, "scheduled", "cloned jobs are scheduled");
is($job->{clone_id}, undef, "no clones");
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
$id = OpenQA::Scheduler::job_duplicate(jobid => $jobE);
ok(defined $id, "duplicate works");

$job = OpenQA::Scheduler::job_get($jobA); #cloned
is($job->{state}, "done", "no change");
is($job->{result}, "failed", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobA2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobB); # unchanged
is($job->{state}, "running", "no change");
is($job->{clone_id}, $jobB2, "cloned");


$job = OpenQA::Scheduler::job_get($jobC); # unchanged
is($job->{state}, "running", "no change");
is($job->{clone_id}, $jobC2, "cloned");

$job = OpenQA::Scheduler::job_get($jobD); #cloned
is($job->{state}, "done", "no change");
is($job->{result}, "incomplete", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobD2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobE); #cloned
is($job->{state}, "done", "no change");
is($job->{result}, "incomplete", "no change");
ok(defined $job->{clone_id}, "cloned");
my $jobE2 = $job->{clone_id};

$job = OpenQA::Scheduler::job_get($jobF); # unchanged
is($job->{state}, "running", "no change");
is($job->{clone_id}, $jobF2, "cloned");

$job = OpenQA::Scheduler::job_get($jobA2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
is_deeply($job->{parents}, [], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobB2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
is_deeply($job->{parents}, [], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobC2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
is_deeply($job->{parents}, [$jobB2], "cloned deps");


$job = OpenQA::Scheduler::job_get($jobD2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
is_deeply($job->{parents}, [$jobA2], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobE2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
is_deeply([sort @{$job->{parents}}],[sort ($jobC2, $jobD2)], "cloned deps");

$job = OpenQA::Scheduler::job_get($jobF2);
is($job->{state}, "scheduled", "no change");
is($job->{clone_id}, undef, "no clones");
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
my $worker = OpenQA::Scheduler::worker_get($w2_id);

my $t = Test::Mojo->new('OpenQA');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $worker->{'properties'}->{'JOBTOKEN'});
    }
);

$t->get_ok('/api/v1/mm/children/running')->status_is(200)->json_is('/jobs' => [$jobF]);
$t->get_ok('/api/v1/mm/children/scheduled')->status_is(200)->json_is('/jobs' => []);
$t->get_ok('/api/v1/mm/children/done')->status_is(200)->json_is('/jobs' => [$jobE]);

done_testing();
