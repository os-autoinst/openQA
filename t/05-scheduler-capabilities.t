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
use Test::More tests => 6;

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

my %workercaps64;
$workercaps64{cpu_modelname} = 'Rainbow CPU';
$workercaps64{cpu_arch} = 'x86_64';
$workercaps64{cpu_opmode} = '32-bit, 64-bit';
$workercaps64{mem_max} = '4096';

my %workercaps64_server = %workercaps64;
$workercaps64_server{worker_class} = 'server';

my %workercaps64_client = %workercaps64;
$workercaps64_client{worker_class} = 'client';

my %workercaps32;
$workercaps32{cpu_modelname} = 'Rainbow CPU';
$workercaps32{cpu_arch} = 'i686';
$workercaps32{cpu_opmode} = '32-bit';
$workercaps32{mem_max} = '4096';


my %settingsA = %settings;
my %settingsB = %settings;
my %settingsC = %settings;
my %settingsD = %settings;
my %settingsE = %settings;
my %settingsF = %settings;
my %settingsG = %settings;

$settingsA{TEST} = 'A';
$settingsA{WORKER_CLASS} = 'client';

$settingsB{TEST} = 'B';
$settingsB{WORKER_CLASS} = 'server';

$settingsC{TEST} = 'C';
$settingsC{ARCH} = 'i686';

$settingsD{TEST} = 'D';

$settingsE{TEST} = 'E';
$settingsE{ARCH} = 'i686';

$settingsF{TEST} = 'F';

$settingsG{TEST} = 'G';
$settingsG{WORKER_CLASS} = 'special';


my $jobA = OpenQA::Scheduler::job_create(\%settingsA);
my $jobB = OpenQA::Scheduler::job_create(\%settingsB);
my $jobC = OpenQA::Scheduler::job_create(\%settingsC);
my $jobD = OpenQA::Scheduler::job_create(\%settingsD);
my $jobE = OpenQA::Scheduler::job_create(\%settingsE);
my $jobF = OpenQA::Scheduler::job_create(\%settingsF);
my $jobG = OpenQA::Scheduler::job_create(\%settingsG);

OpenQA::Scheduler::job_set_prio(jobid => $jobA, prio => 3);
OpenQA::Scheduler::job_set_prio(jobid => $jobB, prio => 2);
OpenQA::Scheduler::job_set_prio(jobid => $jobC, prio => 7);
OpenQA::Scheduler::job_set_prio(jobid => $jobD, prio => 6);
OpenQA::Scheduler::job_set_prio(jobid => $jobE, prio => 5);
OpenQA::Scheduler::job_set_prio(jobid => $jobF, prio => 4);
OpenQA::Scheduler::job_set_prio(jobid => $jobG, prio => 1);

my $w1_id = worker_register("host", "1", "backend", \%workercaps64_client);
my $w2_id = worker_register("host", "2", "backend", \%workercaps64_server);
my $w3_id = worker_register("host", "3", "backend", \%workercaps32);
my $w4_id = worker_register("host", "4", "backend", \%workercaps64);
my $w5_id = worker_register("host", "5", "backend", \%workercaps64_client);
my $w6_id = worker_register("host", "6", "backend", \%workercaps64);

my $job = OpenQA::Scheduler::job_grab(workerid => $w1_id);
is($job->{id}, $jobA, "'client' worker should get 'client' job even though 'server' job has higher prio");

$job = OpenQA::Scheduler::job_grab(workerid => $w2_id);
is($job->{id}, $jobB, "'server' job for 'server' worker");

$job = OpenQA::Scheduler::job_grab(workerid => $w3_id);
is($job->{id}, $jobE, "32bit worker gets 32bit job with highest prio");

$job = OpenQA::Scheduler::job_grab(workerid => $w4_id);
is($job->{id}, $jobF, "next job by prio");

$job = OpenQA::Scheduler::job_grab(workerid => $w5_id);
is($job->{id}, $jobD, "next job by prio, 'client' worker can do jobs without class");

$job = OpenQA::Scheduler::job_grab(workerid => $w6_id);
is($job->{id}, $jobC, "next job by prio, 64bit worker can get 32bit job");

# job G is not grabbed because there is no worker with class 'special'

done_testing();
