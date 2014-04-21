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

my @ret = Scheduler::job_restart(99927);
is(@ret, 0, "no job ids returned");

$jobs = list_jobs();
is_deeply($jobs, $current_jobs, "jobs unchanged after restarting scheduled job");

Scheduler::job_cancel(99927);
$job1 = Scheduler::job_get(99927);
is($job1->{state}, 'cancelled', "scheduled job cancelled after cancelled");

$job1 = Scheduler::job_get(99937);
@ret = Scheduler::job_restart(99937);
$job2 = Scheduler::job_get(99937);

is($job2->{clone_id}, 99983, "clone is tracked");
$job1->{clone_id} = 99983; # Just for comparing
is_deeply($job1, $job2, "done job unchanged after restart");

is(@ret, 1, "one job id returned");
$job2 = Scheduler::job_get($ret[0]);

isnt($job1->{id}, $job2->{id}, "new job has a different id");
is($job2->{state}, 'scheduled', "new job is scheduled");

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

my $job3 = Scheduler::job_get(99928);
is($job3->{retry_avbl}, 3, "the retry counter decreased");
my $round1_id = Scheduler::job_duplicate((jobid => 99928, dup_type_auto => 1));
ok(defined $round1_id, "auto-duplicate works");
$job3 = Scheduler::job_get($round1_id);
is($job3->{retry_avbl}, 2, "the retry counter decreased");
my $round2_id = Scheduler::job_duplicate((jobid => $round1_id, dup_type_auto => 1));
ok(defined $round2_id, "auto-duplicate works");
$job3 = Scheduler::job_get($round2_id);
is($job3->{retry_avbl}, 1, "the retry counter decreased");
my $round3_id = Scheduler::job_duplicate((jobid => $round2_id, dup_type_auto => 1));
ok(defined $round3_id, "auto-duplicate works");
$job3 = Scheduler::job_get($round3_id);
is($job3->{retry_avbl}, 0, "the retry counter decreased");
my $round4_id = Scheduler::job_duplicate((jobid => $round3_id, dup_type_auto => 1));
ok(!defined $round4_id, "auto-duplicate works");
my $round5_id = Scheduler::job_duplicate(jobid => $round3_id);
ok(defined $round5_id, "manual-duplicate works");
$job3 = Scheduler::job_get($round5_id);
is($job3->{retry_avbl}, 1, "the retry counter increased");

done_testing;
