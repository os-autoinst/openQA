#!/usr/bin/perl -w

BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use strict;
use Data::Dump qw/pp dd/;
use Scheduler;
use openqa;
use OpenQA::Test::Database;

use Test::More;

ok(OpenQA::Test::Database->new->create(), "create database") || BAIL_OUT("failed to create database");

my $current_jobs = list_jobs();
ok(@$current_jobs, "have jobs");

my $job1 = Scheduler::job_get(99927);
my $id = Scheduler::job_duplicate(jobid => 99927);
ok(defined $id, "duplicate works");

my $jobs = list_jobs();
is(@$jobs, @$current_jobs+1, "one more job after duplicating one job");

$current_jobs = $jobs;

my $job2 = Scheduler::job_get($id);
delete $job1->{id};
delete $job1->{settings}->{NAME};
delete $job2->{id};
delete $job2->{settings}->{NAME};
is_deeply($job1, $job2, "duplicated job equal");

Scheduler::job_restart(99927);

$jobs = list_jobs();
is_deeply($jobs, $current_jobs, "jobs unchanged after restarting scheduled job");

Scheduler::job_cancel(99927);
$job1 = Scheduler::job_get(99927);
is($job1->{state}, 'cancelled', "scheduled job cancelled after cancelled");

$job1 = Scheduler::job_get(99937);
Scheduler::job_restart(99937);
$job2 = Scheduler::job_get(99937);

is_deeply($job1, $job2, "done job unchanged after restart");

$jobs = list_jobs();

is(@$jobs, @$current_jobs+1, "one more job after restarting done job");

$current_jobs = $jobs;

my $commands = Scheduler::list_commands();
is_deeply($commands, [], "no commands queued");

Scheduler::job_restart(99963);

$jobs = list_jobs();
is(@$jobs, @$current_jobs+1, "one more job after restarting running job");

$commands = Scheduler::list_commands();
is($commands->[0]->{command}, 'abort', "abort command queued");
is($commands->[0]->{worker_id}, '1', "for worker 1");

Scheduler::command_dequeue(workerid => $commands->[0]->{worker_id}, id => $commands->[0]->{id});
$commands = Scheduler::list_commands();
is_deeply($commands, [], "command dequeued");

$job1 = Scheduler::job_get(99963);
Scheduler::job_cancel(99963);
$job2 = Scheduler::job_get(99963);

is_deeply($job1, $job2, "running job unchanged after cancel");

$commands = Scheduler::list_commands();
is($commands->[0]->{command}, 'cancel', "cancel command queued");
is($commands->[0]->{worker_id}, '1', "for worker 1");

Scheduler::command_dequeue(workerid => $commands->[0]->{worker_id}, id => $commands->[0]->{id});
$commands = Scheduler::list_commands();
is_deeply($commands, [], "command dequeued");

done_testing;
