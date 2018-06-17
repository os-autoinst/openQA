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
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::ResourceAllocator;
use OpenQA::Resource::Locks;
use OpenQA::Resource::Jobs;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use Net::DBus;
use Net::DBus::Test::MockObject;

use Test::More;
use Test::Warnings;
use Test::Output qw(stderr_like);

my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1);

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(%args)->all];
}

sub job_get {
    my ($id) = @_;
    my $job = $schema->resultset("Jobs")->find({id => $id});
    return $job;
}

sub job_get_hash {
    my ($id) = @_;

    my $job = job_get($id);
    return unless $job;
    my $ref = $job->to_hash(assets => 1);
    $ref->{worker_id} = $job->worker_id;
    return $ref;
}

my $result;

sub nots {
    my $h  = shift;
    my @ts = @_;
    unshift @ts, 't_updated', 't_created';
    for (@ts) {
        delete $h->{$_};
    }
    return $h;
}

# create Test DBus bus and service for fake WebSockets
my $ws = OpenQA::WebSockets->new();
my $sh = OpenQA::Scheduler->new();
my $ra = OpenQA::ResourceAllocator->new();

my $current_jobs = list_jobs();
is_deeply($current_jobs, [], "assert database has no jobs to start with")
  or BAIL_OUT("database not properly initialized");

# Testing worker_register and worker_get
# New worker

my $workercaps = {};
$workercaps->{cpu_modelname}                = 'Rainbow CPU';
$workercaps->{cpu_arch}                     = 'x86_64';
$workercaps->{cpu_opmode}                   = '32-bit, 64-bit';
$workercaps->{mem_max}                      = '4096';
$workercaps->{websocket_api_version}        = WEBSOCKET_API_VERSION;
$workercaps->{isotovideo_interface_version} = WEBSOCKET_API_VERSION;

use OpenQA::WebAPI::Controller::API::V1::Worker;
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;

# this really should be an integration test
my $id = $c->_register($schema, "host", "1", $workercaps);
ok($id == 1, "New worker registered");
my $worker = $schema->resultset("Workers")->find($id)->info();
ok($worker->{id} == $id && $worker->{host} eq "host" && $worker->{instance} eq "1", "New worker_get");

# Update worker
sleep(1);
my $id2 = $c->_register($schema, "host", "1", $workercaps);
ok($id == $id2, "Known worker_register");
my $worker2 = $schema->resultset("Workers")->find($id2)->info();
ok($worker2->{id} == $id2 && $worker2->{host} eq "host" && $worker2->{instance} == 1, "Known worker_get");

# Testing job_create and job_get
my %settings = (
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => '666',
    TEST        => 'rainbow',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64'
);

my $job_ref = {
    t_finished => undef,
    id         => 1,
    name       => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
    priority   => 40,
    result     => 'none',
    settings   => {
        DESKTOP     => "DESKTOP",
        DISTRI      => 'Unicorn',
        FLAVOR      => 'pink',
        VERSION     => '42',
        BUILD       => '666',
        TEST        => 'rainbow',
        ISO         => 'whatever.iso',
        ISO_MAXSIZE => 1,
        KVM         => "KVM",
        MACHINE     => "RainbowPC",
        ARCH        => 'x86_64',
        NAME        => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
    },
    assets => {
        iso => ['whatever.iso'],
    },
    t_started => undef,
    state     => "scheduled",
    worker_id => 0,
    clone_id  => undef,
    group_id  => undef,
    # to be removed
    test => 'rainbow'
};

my $iso = sprintf("%s/iso/%s", $OpenQA::Utils::assetdir, $settings{ISO});
my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
is($job->id, 1, "job_create");

my %settings2 = %settings;
$settings2{NAME}  = "OTHER NAME";
$settings2{BUILD} = "44";
my $job2 = $schema->resultset('Jobs')->create_from_settings(\%settings2);
is($job2->id, 2);

subtest 'calling again with same settings' => sub {
    my $job3 = $schema->resultset('Jobs')->create_from_settings(\%settings2);
    is($job3->id, 3, 'calling again with same settings yields new job');
    $schema->resultset('Jobs')->find($job3->id)->delete;
};

$job->set_prio(40);
my $new_job = job_get_hash($job->id);
is_deeply($new_job, $job_ref, "job_get");

# Testing list_jobs
my $jobs = [
    {
        t_finished => undef,
        id         => 2,
        name       => 'Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
        priority   => 50,
        result     => 'none',
        t_started  => undef,
        state      => "scheduled",
        test       => 'rainbow',
        clone_id   => undef,
        group_id   => undef,
        settings   => {
            DESKTOP     => "DESKTOP",
            DISTRI      => 'Unicorn',
            FLAVOR      => 'pink',
            VERSION     => '42',
            BUILD       => '44',
            TEST        => 'rainbow',
            ISO         => 'whatever.iso',
            ISO_MAXSIZE => 1,
            KVM         => "KVM",
            MACHINE     => "RainbowPC",
            ARCH        => 'x86_64',
            NAME        => '00000002-Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
        },
        assets => {
            iso => ['whatever.iso'],
        },
    },
    {
        t_finished => undef,
        id         => 1,
        name       => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
        priority   => 40,
        result     => 'none',
        t_started  => undef,
        state      => "scheduled",
        test       => 'rainbow',
        clone_id   => undef,
        group_id   => undef,
        settings   => {
            DESKTOP     => "DESKTOP",
            DISTRI      => 'Unicorn',
            FLAVOR      => 'pink',
            VERSION     => '42',
            BUILD       => '666',
            TEST        => 'rainbow',
            ISO         => 'whatever.iso',
            ISO_MAXSIZE => 1,
            KVM         => "KVM",
            MACHINE     => "RainbowPC",
            ARCH        => 'x86_64',
            NAME        => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
        },
        assets => {
            iso => ['whatever.iso'],
        },
    },
];

$current_jobs = list_jobs();
is_deeply($current_jobs, $jobs, "All list_jobs");

my %args = (state => "scheduled");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "All list_jobs with state scheduled");

%args = (state => "running");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [], "All list_jobs with state running");

%args = (build => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs with build");

%args = (iso => "whatever.iso");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "list_jobs with iso");

%args = (build => "666", state => "scheduled");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs combining a setting (BUILD) and state");

%args = (iso => "whatever.iso", build => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs combining two settings (ISO and BUILD)");

%args = (build => "whatever.iso", iso => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [], "list_jobs messing two settings up");

%args = (ids => [1, 2], state => ["scheduled", "done"]);
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "jobs with specified IDs and states (array ref)");

%args = (ids => "2,3", state => "scheduled,done");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[0]], "jobs with specified IDs (comma list)");

# Testing job_grab
%args = (workerid => $worker->{id}, allocate => 1);
my $rjobs_before = list_jobs(state => 'running');
my $grabbed      = OpenQA::Scheduler::Scheduler::job_grab(%args);
my $rjobs_after  = list_jobs(state => 'running');

## test and add JOBTOKEN to job_ref after job_grab
ok($grabbed->{settings}->{JOBTOKEN}, "job token present");
$job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
is_deeply($grabbed->{settings}, $job_ref->{settings}, "settings correct");
ok($grabbed->{t_started} =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job start timestamp updated");
is(scalar(@{$rjobs_before}) + 1, scalar(@{$rjobs_after}), "number of running jobs");
is($rjobs_after->[-1]->{assigned_worker_id}, 1, 'assigned worker set');

$grabbed = job_get($job->id);
is($grabbed->worker->id, $worker->{id}, "correct worker assigned");
ok($grabbed->state eq "running", "Job is in running state");    # After job_grab the job is in running state.

# register worker again while it has a running job
$id2 = $c->_register($schema, "host", "1", $workercaps);
ok($id == $id2, "re-register worker got same id");

# Now it's previous job must be set to done
$grabbed = job_get($job->id);
is($grabbed->state,  "done",       "Previous job is in done state");
is($grabbed->result, "incomplete", "result is incomplete");
ok(!$grabbed->settings_hash->{JOBTOKEN}, "job token no longer present");

$grabbed = OpenQA::Scheduler::Scheduler::job_grab(%args);
isnt($job->id, $grabbed->{id}, "new job grabbed");
isnt($grabbed->{settings}->{JOBTOKEN}, $job_ref->{settings}->{JOBTOKEN}, "job token differs");

## update refs for isdeeply compare
$job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
$job_ref->{settings}->{NAME}     = $grabbed->{settings}->{NAME};

is_deeply($grabbed->{settings}, $job_ref->{settings}, "settings correct");
my $job3_id = $job->id;
my $job_id  = $grabbed->{id};

sleep 1;
# Testing job_set_done
$job = job_get($job_id);
$result = $job->done(result => 'passed');
is($result, 'passed', "job_set_done");
$job = job_get($job_id);
is($job->state,  "done",   "job_set_done changed state");
is($job->result, "passed", "job_set_done changed result");
ok($job->t_finished =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job end timestamp updated");
ok(!$job->settings_hash->{JOBTOKEN},                          "job token not present after job done");

%args = (result => "passed");
$current_jobs = list_jobs(%args);
is(scalar @{$current_jobs}, 1, "there is one passed job listed");

# we cannot test maxage here as it depends too much on too small
# time slots. The ui tests check maxage instead too
#%args = (maxage => 2);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [$job], "list_jobs with finish in past");
#sleep 1;
#%args = (maxage => 1);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [], "list_jobs with finish in future");

# Testing set_prio
$schema->resultset('Jobs')->find($job_id)->set_prio(100);
$job = job_get($job_id);
is($job->priority, 100, "job->set_prio");

$result = $schema->resultset('Jobs')->find($job_id)->delete;
my $no_job_id = job_get($job_id);
ok($result && !defined $no_job_id, "job_delete");

# Testing double grab
%args   = (workerid => $worker->{id}, allocate => 1);
$job    = OpenQA::Scheduler::Scheduler::job_grab(%args);
$job_id = $job->{id};
$job    = job_get($job_id);
is($job->state, 'running', 'grabbed job runs');

my $job4;
stderr_like {
    $job4 = OpenQA::Scheduler::Scheduler::job_grab(%args);
}
qr/[WARN].*host.*wants to grab a new job - killing the old one: 2/;
isnt($job4->{id}, $job_id, "grabbed another job");
$job->discard_changes;
is($job4->{state}, 'running',    'grabbed job 4 runs');
is($job->state,    'done',       'job 2 no longer runs');
is($job->result,   'incomplete', 'first job set to incomplete');

# Testing job_restart
# TBD

# Testing job_cancel
# TBD

# Testing job_fill_settings
# TBD

$result    = $schema->resultset('Jobs')->find($job2->id)->delete;
$no_job_id = job_get($job2->id);
ok($result && !defined $no_job_id, "job_delete");

$result    = $schema->resultset('Jobs')->find($job3_id)->delete;
$no_job_id = job_get($job3_id);
ok($result && !defined $no_job_id, "job_delete");

$result    = $schema->resultset('Jobs')->find($job4->{id})->delete;
$no_job_id = job_get($job4->{id});
ok($result && !defined $no_job_id, "job_delete");

$current_jobs = list_jobs();
is_deeply($current_jobs, [], "no jobs listed");

my $asset = $schema->resultset('Assets')->register('iso', $settings{ISO});
is($asset->name, $settings{ISO}, "asset register returns same");

subtest 'OpenQA::Setup object test' => sub {
    use OpenQA::Setup;
    my $setup = OpenQA::Setup->new;
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);
    isa_ok($setup->home,   'Mojo::Home');
    isa_ok($setup->schema, 'OpenQA::Schema');
    isa_ok($setup->log,    'Mojo::Log');
};

done_testing;
