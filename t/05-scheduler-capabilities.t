#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Test::Utils 'setup_mojo_app_with_default_worker_timeout';
use OpenQA::WebAPI::Controller::API::V1::Worker;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::Util 'monkey_patch';
use OpenQA::Test::TimeLimit '10';

setup_mojo_app_with_default_worker_timeout;

my $schema = OpenQA::Test::Database->new->create;
my $sent = {};

OpenQA::Scheduler::Model::Jobs->singleton->shuffle_workers(0);

sub schedule {
    my $id = OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    do {
        my $j = $schema->resultset('Jobs')->find($_->{job});
        $j->state(OpenQA::Jobs::Constants::RUNNING);
        $j->update();
      }
      for @$id;
}

# Mangle worker websocket send, and record what was sent
monkey_patch 'OpenQA::Schema::Result::Jobs', ws_send => sub {
    my ($self, $worker) = @_;
    my $hashref = $self->prepare_for_work($worker);
    $hashref->{assigned_worker_id} = $worker->id;
    $sent->{$worker->id} = {worker => $worker, job => $self};
    $sent->{job}->{$self->id} = {worker => $worker, job => $self};
    return {state => {msg_sent => 1}};
};

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(%args)->all];
}

my $current_jobs = list_jobs;
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
$workercaps64{worker_class} = 'qemu_x86_64,qemu_i686';
$workercaps64{cpu_opmode} = '32-bit, 64-bit';
$workercaps64{mem_max} = '4096';
$workercaps64{websocket_api_version} = WEBSOCKET_API_VERSION;
$workercaps64{isotovideo_interface_version} = WEBSOCKET_API_VERSION;

my %workercaps64_server = %workercaps64;
$workercaps64_server{worker_class} = 'server,qemu_x86_64';

my %workercaps64_client = %workercaps64;
$workercaps64_client{worker_class} = 'client,qemu_x86_64';

my %workercaps32;
$workercaps32{cpu_modelname} = 'Rainbow CPU';
$workercaps32{cpu_arch} = 'i686';
$workercaps32{worker_class} = 'qemu_i686';
$workercaps32{cpu_opmode} = '32-bit';
$workercaps32{mem_max} = '4096';
$workercaps32{websocket_api_version} = WEBSOCKET_API_VERSION;
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

$settingsA{TEST} = 'A';
$settingsA{WORKER_CLASS} = 'client,qemu_x86_64';

$settingsB{TEST} = 'B';
$settingsB{WORKER_CLASS} = 'server,qemu_x86_64';

$settingsC{TEST} = 'C';
$settingsC{ARCH} = 'i686';
$settingsC{WORKER_CLASS} = 'qemu_i686';

# no class for D
$settingsD{TEST} = 'D';

$settingsE{TEST} = 'E';
$settingsE{ARCH} = 'i686';
$settingsE{WORKER_CLASS} = 'qemu_i686';

$settingsF{TEST} = 'F';
$settingsF{WORKER_CLASS} = 'qemu_x86_64';

$settingsG{TEST} = 'G';
$settingsG{WORKER_CLASS} = 'special,qemu_x86_64';

$settingsH{TEST} = 'H';
$settingsH{WORKER_CLASS} = 'server,qemu_x86_64';

$settingsI{TEST} = 'I';
$settingsI{WORKER_CLASS} = 'client,qemu_x86_64';

$settingsJ{TEST} = 'J';
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

schedule() for ($jobA, $jobB, $jobE, $jobF, $jobD, $jobC, $jobH, $jobJ, $jobI);
ok exists $sent->{job}->{$_}, "$_ exists"
  for (map { $_->id } $jobA, $jobB, $jobE, $jobF, $jobD, $jobC, $jobH, $jobJ, $jobI);

my $job = $sent->{$w1_id}->{job}->to_hash;
is($job->{id}, $jobA->id, "'client' worker should get 'client' job even though 'server' job has higher prio");

$job = $sent->{$w2_id}->{job}->to_hash;
is($job->{id}, $jobB->id, "'server' job for 'server' worker");

$job = $sent->{$w3_id}->{job}->to_hash;
is($job->{id}, $jobE->id, "32bit worker gets 32bit job with highest prio");

$job = $sent->{$w4_id}->{job}->to_hash;
is($job->{id}, $jobF->id, "next job by prio");

$job = $sent->{$w5_id}->{job}->to_hash;
is($job->{id}, $jobD->id, "next job by prio, 'client' worker can do jobs without class");

$job = $sent->{$w6_id}->{job}->to_hash;
is($job->{id}, $jobC->id, "next job by prio, 64bit worker can get 32bit job");

$job = $sent->{$w7_id}->{job}->to_hash;
is($job->{id}, $jobH->id, "next job by prio, parent - server");

$job = $sent->{$w8_id}->{job}->to_hash;
is($job->{id}, $jobJ->id,
"I is a scheduled child of running H so it should have the highest prio, but this worker can't do it because of class -> take next job by prio instead"
);

$job = $sent->{$w9_id}->{job}->to_hash;
is($job->{id}, $jobI->id, "this worker can do jobI, child - client");

# job G is not grabbed because there is no worker with class 'special'

done_testing();
