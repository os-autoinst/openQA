#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
use Data::Dump qw/pp dd/;
use Scheduler;
use openqa;

use Test::Simple tests => 26;


# Testing worker_register and worker_get
# New worker
my $id = worker_register("host", "instance", "backend");
ok($id == 1, "New worker registered");
my $worker = worker_get($id);
ok($worker->{id} == $id
   && $worker->{host} eq "host"
   && $worker->{instance} eq "instance"
   && $worker->{backend} eq "backend", "New worker_get");

# Update worker
sleep(1);
my $id2 = worker_register("host", "instance", "backend");
ok($id == $id2, "Old worker_register");
my $worker2 = worker_get($id2);
ok($worker2->{id} == $id2
   && $worker2->{host} eq "host"
   && $worker2->{instance} eq "instance"
   && $worker2->{backend} eq "backend"
   && $worker2->{seen} ne $worker->{seen}, "Old worker_get");


# Testing list_workers
my $workers_ref = list_workers();
ok(scalar @$workers_ref == 2
   && pp($workers_ref->[1]) eq pp($worker2) , "list_workers");


# Testing job_create and job_get
my %settings = (
    DISTRI => 'DISTRI',
    ISO => 'ISO',
    DESKTOP => 'DESKTOP',
    NAME => 'NAME',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    );

my $job = {
    finish_date => undef,
    id => 1,
    name => "NAME",
    priority => 50,
    result => undef,
    settings => {
	DESKTOP => "DESKTOP",
	DISTRI => "DISTRI",
	ISO => "ISO",
	ISO_MAXSIZE => 1,
	KVM => "KVM",
	NAME => "NAME",
    },
    start_date => undef,
    state => "scheduled",
    worker_id => 0,
    };

my $iso = sprintf("%s/%s/factory/iso/%s", $openqa::basedir, $openqa::prj, $settings{ISO});
open my $fh, ">", $iso;
my $job_id = Scheduler::job_create(%settings);
ok($job_id == 1, "job_create");
unlink $iso;

my $new_job = Scheduler::job_get($job_id);
ok(pp($job) eq pp($new_job), "job_get");


# Testing list_jobs
my $jobs = [
    {
	finish_date => undef,
	id => 1,
	name => "NAME",
	priority => 50,
	result => undef,
	start_date => undef,
	state => "scheduled",
	worker_id => 0,
    },
    ];

my $current_jobs = list_jobs();
ok(pp($current_jobs) eq pp($jobs), "All list_jobs");

my %state = (state => "scheduled");
$current_jobs = list_jobs(%state);
ok(pp($current_jobs) eq pp($jobs), "All list_jobs with state scheduled");

%state = (state => "running");
$current_jobs = list_jobs(%state);
ok(pp($current_jobs) eq "[]", "All list_jobs with state running");


# Testing job_grab
my %args = (
    workerid => $worker->{id},
    );
$job = job_grab(%args);
ok(pp($job->{settings}) eq pp(\%settings) && length $job->{start_date} == 19, "job_grab");


# # Testing when a worker register for second time and had pending jobs
# $id2 = worker_register("host", "instance", "backend");
# ok($id == $id2, "Pending jobs worker_register");


# Testing job_set_scheduled
$job = Scheduler::job_get($job_id);
ok($job->{state} eq "running", "Job is in running state");   # After job_grab the job is in running state.
my $result = Scheduler::job_set_scheduled($job_id);
$job = Scheduler::job_get($job_id);
ok($result == 1&& $job->{state} eq "scheduled", "job_set_scheduled");


# Testing job_set_done
%args = (
    jobid => $job_id,
    result => 0,
    );
$result = Scheduler::job_set_done(%args);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "done", "job_set_done");


# Testing job_set_stop
$result = Scheduler::job_set_stop($job_id);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "stopped", "job_set_stop");


# Testing job_set_waiting
$result = Scheduler::job_set_waiting($job_id);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "waiting", "job_set_waiting");


# Testing job_set_running
$result = Scheduler::job_set_running($job_id);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{state} eq "running", "job_set_running");
$result = Scheduler::job_set_running($job_id);
$job = Scheduler::job_get($job_id);
ok($result == 0 && $job->{state} eq "running", "Retry job_set_running");


# Testing job_set_prio
%args = (
    jobid => $job_id,
    prio => 100,
    );
$result = Scheduler::job_set_prio(%args);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{priority} == 100, "job_set_prio");


# Testing job_update_result
%args = (
    jobid => $job_id,
    result => 1,
    );
$result = Scheduler::job_update_result(%args);
$job = Scheduler::job_get($job_id);
ok($result == 1 && $job->{result} == 1, "job_update_result");


# Testing job_restart
# TBD

# Testing job_stop
# TBD

# Testing job_fill_settings
# TBD


# Testing job_delete
$result = Scheduler::job_delete($job_id);
my $no_job_id = Scheduler::job_get($job_id);
ok($result == 1 && !defined $no_job_id, "job_delete");
my $fake_job = { id => $job_id };
Scheduler::_job_fill_settings($fake_job);
ok(pp($fake_job->{settings}) eq "{}", "Cascade delete");


# Testing command_enqueue and list_commands
%args = (
    workerid => $id,
    command => "command",
    );
my %command = (
    id => 1,
    worker_id => 1,
    command => "command",
    );
my $command_id = Scheduler::command_enqueue(%args);
my $commands = Scheduler::list_commands();
ok($command_id == 1
   && scalar @$commands == 1
   && pp($commands->[0]) eq pp(\%command),  "command_enqueue and list_commands");


# Testing command_get
$commands = Scheduler::command_get($command_id);
ok(scalar @$commands == 1 && pp($commands) eq '[[1, "command"]]',  "command_get");


# Testing command_dequeue
# TBD

# Testing iso_stop_old_builds
$result = Scheduler::iso_stop_old_builds('ISO');
ok($result == 0, "Empty iso_old_builds");
open $fh, ">", $iso;
$job_id = Scheduler::job_create(%settings);
unlink $iso;
$result = Scheduler::iso_stop_old_builds('ISO');
$new_job = Scheduler::job_get($job_id);
ok($result == 1 && $new_job->{state} eq "stopped" && $new_job->{worker_id} == 0, "Match iso_old_builds");

