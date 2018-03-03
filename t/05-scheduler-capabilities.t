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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd);
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use Test::Mojo;
use Test::More;
use Test::Warnings;

my $schema = OpenQA::Test::Database->new->create;    #(skip_fixtures => 1);

#my $t = Test::Mojo->new('OpenQA::WebAPI');

# create Test DBus bus and service for fake WebSockets call
my $ws = OpenQA::WebSockets->new;

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(%args)->all];
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

my %workercaps64;
$workercaps64{cpu_modelname}                = 'Rainbow CPU';
$workercaps64{cpu_arch}                     = 'x86_64';
$workercaps64{worker_class}                 = 'qemu_x86_64,qemu_i686';
$workercaps64{cpu_opmode}                   = '32-bit, 64-bit';
$workercaps64{mem_max}                      = '4096';
$workercaps64{websocket_api_version}        = WEBSOCKET_API_VERSION;
$workercaps64{isotovideo_interface_version} = WEBSOCKET_API_VERSION;

my %workercaps64_server = %workercaps64;
$workercaps64_server{worker_class} = 'server,qemu_x86_64';

my %workercaps64_client = %workercaps64;
$workercaps64_client{worker_class} = 'client,qemu_x86_64';

my %workercaps32;
$workercaps32{cpu_modelname}                = 'Rainbow CPU';
$workercaps32{cpu_arch}                     = 'i686';
$workercaps32{worker_class}                 = 'qemu_i686';
$workercaps32{cpu_opmode}                   = '32-bit';
$workercaps32{mem_max}                      = '4096';
$workercaps32{websocket_api_version}        = WEBSOCKET_API_VERSION;
$workercaps32{isotovideo_interface_version} = WEBSOCKET_API_VERSION;

my %settingsA = %settings;
my %settingsB = %settings;
my %settingsC = %settings;
my %settingsD = %settings;
my %settingsE = %settings;
my %settingsF = %settings;
my %settingsG = %settings;
my %settingsH = %settings;
my %settingsI = %settings;
my %settingsJ = %settings;

$settingsA{TEST}         = 'A';
$settingsA{WORKER_CLASS} = 'client,qemu_x86_64';

$settingsB{TEST}         = 'B';
$settingsB{WORKER_CLASS} = 'server,qemu_x86_64';

$settingsC{TEST}         = 'C';
$settingsC{ARCH}         = 'i686';
$settingsC{WORKER_CLASS} = 'qemu_i686';

# no class for D
$settingsD{TEST} = 'D';

$settingsE{TEST}         = 'E';
$settingsE{ARCH}         = 'i686';
$settingsE{WORKER_CLASS} = 'qemu_i686';

$settingsF{TEST}         = 'F';
$settingsF{WORKER_CLASS} = 'qemu_x86_64';

$settingsG{TEST}         = 'G';
$settingsG{WORKER_CLASS} = 'special,qemu_x86_64';

$settingsH{TEST}         = 'H';
$settingsH{WORKER_CLASS} = 'server,qemu_x86_64';

$settingsI{TEST}         = 'I';
$settingsI{WORKER_CLASS} = 'client,qemu_x86_64';

$settingsJ{TEST}         = 'J';
$settingsJ{WORKER_CLASS} = 'qemu_x86_64';

sub job_create {
    return $schema->resultset('Jobs')->create_from_settings(@_);
}

my $jobA = job_create(\%settingsA);
my $jobB = job_create(\%settingsB);
my $jobC = job_create(\%settingsC);
my $jobD = job_create(\%settingsD);
my $jobE = job_create(\%settingsE);
my $jobF = job_create(\%settingsF);
my $jobG = job_create(\%settingsG);

my $jobH = job_create(\%settingsH);
$settingsI{_PARALLEL_JOBS} = [$jobH->id];
my $jobI = job_create(\%settingsI);
my $jobJ = job_create(\%settingsJ);

$jobA->set_prio(3);
$jobB->set_prio(2);
$jobC->set_prio(7);
$jobD->set_prio(6);
$jobE->set_prio(5);
$jobF->set_prio(4);
$jobG->set_prio(1);
$jobH->set_prio(8);
$jobI->set_prio(10);
$jobJ->set_prio(9);

use OpenQA::WebAPI::Controller::API::V1::Worker;
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;

my $w1_id = $c->_register($schema, "host", "1", \%workercaps64_client);
my $w2_id = $c->_register($schema, "host", "2", \%workercaps64_server);
my $w3_id = $c->_register($schema, "host", "3", \%workercaps32);
my $w4_id = $c->_register($schema, "host", "4", \%workercaps64);
my $w5_id = $c->_register($schema, "host", "5", \%workercaps64_client);
my $w6_id = $c->_register($schema, "host", "6", \%workercaps64);
my $w7_id = $c->_register($schema, "host", "7", \%workercaps64_server);
my $w8_id = $c->_register($schema, "host", "8", \%workercaps64);
my $w9_id = $c->_register($schema, "host", "9", \%workercaps64_client);

my $job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w1_id, allocate => 1);
is($job->{id}, $jobA->id, "'client' worker should get 'client' job even though 'server' job has higher prio");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w2_id, allocate => 1);
is($job->{id}, $jobB->id, "'server' job for 'server' worker");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w3_id, allocate => 1);
is($job->{id}, $jobE->id, "32bit worker gets 32bit job with highest prio");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w4_id, allocate => 1);
is($job->{id}, $jobF->id, "next job by prio");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w5_id, allocate => 1);
is($job->{id}, $jobD->id, "next job by prio, 'client' worker can do jobs without class");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w6_id, allocate => 1);
is($job->{id}, $jobC->id, "next job by prio, 64bit worker can get 32bit job");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w7_id, allocate => 1);
is($job->{id}, $jobH->id, "next job by prio, parent - server");

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w8_id, allocate => 1);
is($job->{id}, $jobJ->id,
"I is a scheduled child of running H so it should have the highest prio, but this worker can't do it because of class -> take next job by prio instead"
);

$job = OpenQA::Scheduler::Scheduler::job_grab(workerid => $w9_id, allocate => 1);
is($job->{id}, $jobI->id, "this worker can do jobI, child - client");


# job G is not grabbed because there is no worker with class 'special'

done_testing();
