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
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Net::DBus;
use Net::DBus::Test::MockObject;

use Test::More tests => 55;

my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1);

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } OpenQA::Scheduler::Scheduler::query_jobs(%args)->all];
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
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new();
my $sh  = OpenQA::Scheduler->new();

my $current_jobs = list_jobs();
is_deeply($current_jobs, [], "assert database has no jobs to start with")
  or BAIL_OUT("database not properly initialized");

# Testing worker_register and worker_get
# New worker

my $workercaps = {};
$workercaps->{cpu_modelname} = 'Rainbow CPU';
$workercaps->{cpu_arch}      = 'x86_64';
$workercaps->{cpu_opmode}    = '32-bit, 64-bit';
$workercaps->{mem_max}       = '4096';

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
    name       => 'Unicorn-42-pink-x86_64-Build666-rainbow',
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
        NAME        => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow',
    },
    assets => {
        iso => ['whatever.iso'],
    },
    t_started  => undef,
    state      => "scheduled",
    worker_id  => 0,
    clone_id   => undef,
    group_id   => undef,
    retry_avbl => 3,
    test       => 'rainbow',
};

my $iso = sprintf("%s/%s", $OpenQA::Utils::isodir, $settings{ISO});
my $job = OpenQA::Scheduler::Scheduler::job_create(\%settings);
is($job->id, 1, "job_create");

my %settings2 = %settings;
$settings2{NAME}  = "OTHER NAME";
$settings2{BUILD} = "44";
my $job2 = OpenQA::Scheduler::Scheduler::job_create(\%settings2);

$job->set_prio(40);
my $new_job = OpenQA::Scheduler::Scheduler::job_get($job->id);
is_deeply($new_job, $job_ref, "job_get");

# Testing list_jobs
my $jobs = [
    {
        t_finished => undef,
        id         => 2,
        name       => "OTHER NAME",
        priority   => 50,
        result     => 'none',
        t_started  => undef,
        state      => "scheduled",
        worker_id  => 0,
        test       => 'rainbow',
        clone_id   => undef,
        group_id   => undef,
        retry_avbl => 3,
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
            NAME        => '00000002-OTHER NAME',
        },
        assets => {
            iso => ['whatever.iso'],
        },
    },
    {
        t_finished => undef,
        id         => 1,
        name       => 'Unicorn-42-pink-x86_64-Build666-rainbow',
        priority   => 40,
        result     => 'none',
        t_started  => undef,
        state      => "scheduled",
        worker_id  => 0,
        test       => 'rainbow',
        clone_id   => undef,
        group_id   => undef,
        retry_avbl => 3,
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
            NAME        => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow',
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
%args = (workerid => $worker->{id},);
my $rjobs_before = list_jobs(state => 'running');
my $grabed       = OpenQA::Scheduler::Scheduler::job_grab(%args);
my $rjobs_after  = list_jobs(state => 'running');

## test and add JOBTOKEN to job_ref after job_grab
ok($grabed->{settings}->{JOBTOKEN}, "job token present");
$job_ref->{settings}->{JOBTOKEN} = $grabed->{settings}->{JOBTOKEN};
is_deeply($grabed->{settings}, $job_ref->{settings}, "settings correct");
ok($grabed->{t_started} =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job start timestamp updated");
is(scalar(@{$rjobs_before}) + 1, scalar(@{$rjobs_after}), "number of running jobs");
is($grabed->{worker_id},         $worker->{id},           "correct worker assigned");

$grabed = OpenQA::Scheduler::Scheduler::job_get($job->id);
ok($grabed->{state} eq "running", "Job is in running state");    # After job_grab the job is in running state.

# register worker again while it has a running job
$id2 = $c->_register($schema, "host", "1", $workercaps);
ok($id == $id2, "re-register worker got same id");

# Now it's previous job must be set to done
$grabed = OpenQA::Scheduler::Scheduler::job_get($job->id);
is($grabed->{state},  "done",       "Previous job is in done state");
is($grabed->{result}, "incomplete", "result is incomplete");
ok(!$grabed->{settings}->{JOBTOKEN}, "job token no longer present");

$grabed = OpenQA::Scheduler::Scheduler::job_grab(%args);
isnt($job->id, $grabed->{id}, "new job grabbed");
isnt($grabed->{settings}->{JOBTOKEN}, $job_ref->{settings}->{JOBTOKEN}, "job token differs");
$job_ref->{settings}->{NAME} = '00000003-Unicorn-42-pink-x86_64-Build666-rainbow';

## update JOBTOKEN for isdeeply compare
$job_ref->{settings}->{JOBTOKEN} = $grabed->{settings}->{JOBTOKEN};
is_deeply($grabed->{settings}, $job_ref->{settings}, "settings correct");
my $job3_id = $job->id;
my $job_id  = $grabed->{id};

# Testing job_set_waiting
$result = OpenQA::Scheduler::Scheduler::job_set_waiting($job_id);
$job    = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "waiting", "job_set_waiting");

# Testing job_set_running
$result = OpenQA::Scheduler::Scheduler::job_set_running($job_id);
$job    = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "running", "job_set_running");
$result = OpenQA::Scheduler::Scheduler::job_set_running($job_id);
$job    = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "running", "Retry job_set_running");


sleep 1;
# Testing job_set_done
%args = (
    jobid  => $job_id,
    result => 'passed',
);
$result = OpenQA::Scheduler::Scheduler::job_set_done(%args);
ok($result, "job_set_done");
$job = OpenQA::Scheduler::Scheduler::job_get($job_id);
is($job->{state},  "done",   "job_set_done changed state");
is($job->{result}, "passed", "job_set_done changed result");
ok($job->{t_finished} =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job end timestamp updated");
ok(!$job->{settings}->{JOBTOKEN},                               "job token not present after job done");

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

# Testing job_set_waiting on job not in running state
$result = OpenQA::Scheduler::Scheduler::job_set_waiting($job_id);
$job    = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "done", "job_set_waiting on done job");


# Testing job_set_running on done job
$result = OpenQA::Scheduler::Scheduler::job_set_running($job_id);
$job    = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "done", "job_set_running on done job");

# Testing set_prio
$schema->resultset('Jobs')->find($job_id)->set_prio(100);
$job = OpenQA::Scheduler::Scheduler::job_get($job_id);
is($job->{priority}, 100, "job->set_prio");


# Testing job_update_result
%args = (
    jobid  => $job_id,
    result => 'passed',
);
$result = OpenQA::Scheduler::Scheduler::job_update_result(%args);
ok($result == 1, "job_update_result");
$job = OpenQA::Scheduler::Scheduler::job_get($job_id);
is($job->{result}, $args{result}, "job_get after update");

# Testing job_restart
# TBD

# Testing job_cancel
# TBD

# Testing job_fill_settings
# TBD


# Testing job_delete
$result = OpenQA::Scheduler::Scheduler::job_delete($job_id);
my $no_job_id = OpenQA::Scheduler::Scheduler::job_get($job_id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$result    = OpenQA::Scheduler::Scheduler::job_delete($job2->id);
$no_job_id = OpenQA::Scheduler::Scheduler::job_get($job2->id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$result    = OpenQA::Scheduler::Scheduler::job_delete($job3_id);
$no_job_id = OpenQA::Scheduler::Scheduler::job_get($job3_id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$current_jobs = list_jobs();
is_deeply($current_jobs, [], "no jobs listed");

my $rs = OpenQA::Scheduler::Scheduler::asset_list();
$rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
is_deeply(nots($rs->all()), {id => 1, name => "whatever.iso", type => "iso", size => undef}, "asset list");

my $asset = OpenQA::Scheduler::Scheduler::asset_get(type => 'iso', name => $settings{ISO});
is($asset->single->id, 1, "asset get");

$asset = OpenQA::Scheduler::Scheduler::asset_get(id => 1);
is($asset->single->name, "whatever.iso", "asset get by id");

$asset = OpenQA::Scheduler::Scheduler::asset_get(id => 2);
is($asset->single, undef, "asset get with unassigned id");

$asset = OpenQA::Scheduler::Scheduler::asset_get(blah => "blub");
is($asset, undef, "asset get with invalid args");

$asset = OpenQA::Scheduler::Scheduler::asset_register(type => 'iso', name => $settings{ISO});
is($asset->id, 1, "asset register returns same");

$asset = OpenQA::Scheduler::Scheduler::asset_delete(type => 'iso', name => $settings{ISO});
is($asset, 1, "asset delete");

done_testing;
