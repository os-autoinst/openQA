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

use Test::More tests => 56;

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $result;

sub nots{
    my $h = shift;
    my @ts = @_;
    unshift @ts, 't_updated', 't_created';
    for (@ts) {
        delete $h->{$_};
    }
    return $h;
}

my $current_jobs = list_jobs();
is_deeply($current_jobs, [], "assert database has no jobs to start with")
  or BAIL_OUT("database not properly initialized");

# Testing worker_register and worker_get
# New worker

my $workercaps = {};
$workercaps->{cpu_modelname} = 'Rainbow CPU';
$workercaps->{cpu_arch} = 'x86_64';
$workercaps->{cpu_opmode} = '32-bit, 64-bit';
$workercaps->{mem_max} = '4096';

my $id = worker_register("host", "1", "backend", $workercaps);
ok($id == 1, "New worker registered");
my $worker = worker_get($id);
ok($worker->{id} == $id&& $worker->{host} eq "host"&& $worker->{instance} eq "1"&& $worker->{backend} eq "backend", "New worker_get");

# Update worker
sleep(1);
my $id2 = worker_register("host", "1", "backend", $workercaps);
ok($id == $id2, "Known worker_register");
my $worker2 = worker_get($id2);
ok($worker2->{id} == $id2&& $worker2->{host} eq "host"&& $worker2->{instance} eq "1"&& $worker2->{backend} eq "backend"&& $worker2->{t_updated} ne $worker->{t_updated}, "Known worker_get");

# Testing list_workers
my $workers_ref = list_workers();
is(scalar @$workers_ref, 2, "2 workers");
# check properties independent, list_workers doesn't return it
is(pp($worker2->{properties}), pp({ CPU_ARCH => 'x86_64', CPU_MODELNAME => 'Rainbow CPU', CPU_OPMODE => '32-bit, 64-bit', MEM_MAX => 4096, WORKER_PORT => 20013, WORKER_VNC_PORT => 91 }), "worker properties");
delete $worker2->{properties};
is(pp($workers_ref->[1]), pp($worker2), "list_workers");


# Testing job_create and job_get
my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    TEST => 'rainbow',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE => "RainbowPC",
    ARCH => 'x86_64'
);

my $job_ref = {
    t_finished => undef,
    id => 1,
    name => 'Unicorn-42-pink-x86_64-Build666-rainbow',
    priority => 40,
    result => 'none',
    settings => {
        DESKTOP => "DESKTOP",
        DISTRI => 'Unicorn',
        FLAVOR => 'pink',
        VERSION => '42',
        BUILD => '666',
        TEST => 'rainbow',
        ISO => 'whatever.iso',
        ISO_MAXSIZE => 1,
        KVM => "KVM",
        MACHINE => "RainbowPC",
        ARCH => 'x86_64',
        NAME => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow',
    },
    assets => {
        iso => ['whatever.iso'],
    },
    t_started => undef,
    state => "scheduled",
    worker_id => 0,
    clone_id => undef,
    retry_avbl => 3,
    test => 'rainbow',
    parents => [],
};

my $iso = sprintf("%s/%s", $OpenQA::Utils::isodir, $settings{ISO});
open my $fh, ">", $iso;
my $job_id = OpenQA::Scheduler::job_create(\%settings);
is($job_id, 1, "job_create");

my $assets = OpenQA::Scheduler::job_get_assets($job_id);
is_deeply($assets, [{ id => 1, name => "whatever.iso", type => "iso" }], "job created asset");

my %settings2 = %settings;
$settings2{NAME} = "OTHER NAME";
$settings2{BUILD} = "44";
my $job2_id= OpenQA::Scheduler::job_create(\%settings2);

OpenQA::Scheduler::job_set_prio(jobid => $job_id, prio => 40);
my $new_job = OpenQA::Scheduler::job_get($job_id);
is_deeply($new_job, $job_ref, "job_get");

# Testing list_jobs
my $jobs = [
    {
        t_finished => undef,
        id => 2,
        name => "OTHER NAME",
        priority => 50,
        result => 'none',
        t_started => undef,
        state => "scheduled",
        worker_id => 0,
        test => 'rainbow',
        clone_id => undef,
        retry_avbl => 3,
        settings => {
            DESKTOP => "DESKTOP",
            DISTRI => 'Unicorn',
            FLAVOR => 'pink',
            VERSION => '42',
            BUILD => '44',
            TEST => 'rainbow',
            ISO => 'whatever.iso',
            ISO_MAXSIZE => 1,
            KVM => "KVM",
            MACHINE => "RainbowPC",
            ARCH => 'x86_64',
            NAME => '00000002-OTHER NAME',
        },
        assets => {
            iso => ['whatever.iso'],
        },
        parents => [],
    },
    {
        t_finished => undef,
        id => 1,
        name => 'Unicorn-42-pink-x86_64-Build666-rainbow',
        priority => 40,
        result => 'none',
        t_started => undef,
        state => "scheduled",
        worker_id => 0,
        test => 'rainbow',
        clone_id => undef,
        retry_avbl => 3,
        settings => {
            DESKTOP => "DESKTOP",
            DISTRI => 'Unicorn',
            FLAVOR => 'pink',
            VERSION => '42',
            BUILD => '666',
            TEST => 'rainbow',
            ISO => 'whatever.iso',
            ISO_MAXSIZE => 1,
            KVM => "KVM",
            MACHINE => "RainbowPC",
            ARCH => 'x86_64',
            NAME => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow',
        },
        assets => {
            iso => ['whatever.iso'],
        },
        parents => [],
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

# Testing job_grab
%args = (workerid => $worker->{id},);
my $rjobs_before = OpenQA::Scheduler::list_jobs(state => 'running');
my $job = OpenQA::Scheduler::job_grab(%args);
my $rjobs_after = OpenQA::Scheduler::list_jobs(state => 'running');

## test and add JOBTOKEN to job_ref after job_grab
ok($job->{settings}->{JOBTOKEN}, "job token present");
$job_ref->{settings}->{JOBTOKEN} = $job->{settings}->{JOBTOKEN};
is_deeply($job->{settings}, $job_ref->{settings}, "settings correct");
ok($job->{t_started} =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job start timestamp updated");
is(scalar(@{$rjobs_before})+1, scalar(@{$rjobs_after}), "number of running jobs");
is($job->{worker_id}, $worker->{id}, "correct worker assigned");

$job = OpenQA::Scheduler::job_get($job_id);
ok($job->{state} eq "running", "Job is in running state"); # After job_grab the job is in running state.

# register worker again while it has a running job
$id2 = worker_register("host", "1", "backend", $workercaps);
ok($id == $id2, "re-register worker got same id");

# Now it's previous job must be set to done
$job = OpenQA::Scheduler::job_get($job_id);
is($job->{state}, "done", "Previous job is in done state");
is($job->{result}, "incomplete", "result is incomplete");
ok(!$job->{settings}->{JOBTOKEN}, "job token no longer present");

$job = OpenQA::Scheduler::job_grab(%args);
isnt($job_id, $job->{id}, "new job grabbed");
isnt($job->{settings}->{JOBTOKEN}, $job_ref->{settings}->{JOBTOKEN}, "job token differs");
$job_ref->{settings}->{NAME} = '00000003-Unicorn-42-pink-x86_64-Build666-rainbow';

## update JOBTOKEN for isdeeply compare
$job_ref->{settings}->{JOBTOKEN} = $job->{settings}->{JOBTOKEN};
is_deeply($job->{settings}, $job_ref->{settings}, "settings correct");
my $job3_id = $job_id;
$job_id = $job->{id};

# Testing job_set_waiting
$result = OpenQA::Scheduler::job_set_waiting($job_id);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "waiting", "job_set_waiting");

# Testing job_set_running
$result = OpenQA::Scheduler::job_set_running($job_id);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "running", "job_set_running");
$result = OpenQA::Scheduler::job_set_running($job_id);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "running", "Retry job_set_running");


sleep 1;
# Testing job_set_done
%args = (
    jobid => $job_id,
    result => 'passed',
);
$result = OpenQA::Scheduler::job_set_done(%args);
ok($result, "job_set_done");
$job = OpenQA::Scheduler::job_get($job_id);
is($job->{state}, "done", "job_set_done changed state");
is($job->{result}, "passed", "job_set_done changed result");
ok($job->{t_finished} =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job end timestamp updated");
ok(!$job->{settings}->{JOBTOKEN}, "job token not present after job done");

# we cannot test maxage here as it depends too much on too small
# time slots. The ui tests check maxage instead too
#%args = (maxage => 2, fulldetails => 1);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [$job], "list_jobs with finish in past");
#sleep 1;
#%args = (maxage => 1, fulldetails => 1);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [], "list_jobs with finish in future");

# Testing job_set_waiting on job not in running state
$result = OpenQA::Scheduler::job_set_waiting($job_id);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "done", "job_set_waiting on done job");


# Testing job_set_running on done job
$result = OpenQA::Scheduler::job_set_running($job_id);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "done", "job_set_running on done job");


# Testing job_set_prio
%args = (
    jobid => $job_id,
    prio => 100,
);
$result = OpenQA::Scheduler::job_set_prio(%args);
$job = OpenQA::Scheduler::job_get($job_id);
ok($result == 1 && $job->{priority} == 100, "job_set_prio");


# Testing job_update_result
%args = (
    jobid => $job_id,
    result => 'passed',
);
$result = OpenQA::Scheduler::job_update_result(%args);
ok($result == 1, "job_update_result");
$job = OpenQA::Scheduler::job_get($job_id);
is($job->{result}, $args{result}, "job_get after update");

# Testing job_restart
# TBD

# Testing job_cancel
# TBD

# Testing job_fill_settings
# TBD


# Testing job_delete
$result = OpenQA::Scheduler::job_delete($job_id);
my $no_job_id = OpenQA::Scheduler::job_get($job_id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$result = OpenQA::Scheduler::job_delete($job2_id);
$no_job_id = OpenQA::Scheduler::job_get($job2_id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$result = OpenQA::Scheduler::job_delete($job3_id);
$no_job_id = OpenQA::Scheduler::job_get($job3_id);
ok($result == 1 && !defined $no_job_id, "job_delete");

$current_jobs = list_jobs();
is_deeply($current_jobs, [], "no jobs listed");

my $rs = OpenQA::Scheduler::asset_list();
$rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
is_deeply(nots($rs->all()), { id => 1, name => "whatever.iso", type => "iso" }, "asset list");

my $asset = OpenQA::Scheduler::asset_get(type => 'iso', name => $settings{ISO});
is($asset->single->id, 1, "asset get");

$asset = OpenQA::Scheduler::asset_get(id => 1);
is($asset->single->name, "whatever.iso", "asset get by id");

$asset = OpenQA::Scheduler::asset_get(id => 2);
is($asset->single, undef, "asset get with unassigned id");

$asset = OpenQA::Scheduler::asset_get(blah => "blub");
is($asset, undef, "asset get with invalid args");

$asset = OpenQA::Scheduler::asset_register(type => 'iso', name => $settings{ISO});
is($asset->id, 1, "asset register returns same");

$asset = OpenQA::Scheduler::asset_delete(type => 'iso', name => $settings{ISO});
is($asset, 1, "asset delete");

unlink $iso;
