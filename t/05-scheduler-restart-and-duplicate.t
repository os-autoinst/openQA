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
use OpenQA::Scheduler::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Utils;
use OpenQA::Test::Database;

use Test::More 'no_plan';
use Test::Warnings;


# create Test DBus bus and service for fake WebSockets call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws = OpenQA::WebSockets->new;

sub list_jobs {
    [map { $_->to_hash() } OpenQA::Scheduler::Scheduler::query_jobs()->all];
}

ok(OpenQA::Test::Database->new->create(), "create database") || BAIL_OUT("failed to create database");

my $current_jobs = list_jobs();
ok(@$current_jobs, "have jobs");

my $job1 = OpenQA::Scheduler::Scheduler::job_get(99927);
is($job1->{state}, OpenQA::Schema::Result::Jobs::SCHEDULED, 'trying to duplicate scheduled job');
my $id = OpenQA::Scheduler::Scheduler::job_duplicate(jobid => 99927);
ok(!defined $id, "duplication rejected");

$job1 = OpenQA::Scheduler::Scheduler::job_get(99926);
is($job1->{state}, OpenQA::Schema::Result::Jobs::DONE, 'trying to duplicate done job');
$id = OpenQA::Scheduler::Scheduler::job_duplicate(jobid => 99926);
ok(defined $id, "duplication works");
isnt($id, $job1->{id}, 'clone id is different than original job id');

my $jobs = list_jobs();
is(@$jobs, @$current_jobs + 1, "one more job after duplicating one job");

$current_jobs = $jobs;

my $job2 = OpenQA::Scheduler::Scheduler::job_get($id);
# delete the obviously different fields
delete $job1->{id};
delete $job2->{id};
delete $job1->{state};
delete $job2->{state};
delete $job1->{result};
delete $job2->{result};
delete $job1->{t_finished};
delete $job2->{t_finished};
delete $job1->{t_started};
delete $job2->{t_started};
# the name has job id as prefix, delete that too
delete $job1->{settings}->{NAME};
delete $job2->{settings}->{NAME};
# assets are assigned during job grab and not cloned
delete $job1->{assets};
is_deeply($job1, $job2, "duplicated job equal");

my @ret = OpenQA::Scheduler::Scheduler::job_restart(99926);
is(@ret, 0, "no job ids returned");

$jobs = list_jobs();
is_deeply($jobs, $current_jobs, "jobs unchanged after restarting scheduled job");

OpenQA::Scheduler::Scheduler::job_cancel(99927);
$job1 = OpenQA::Scheduler::Scheduler::job_get(99927);
is($job1->{state}, 'cancelled', "scheduled job cancelled after cancel");

$job1 = OpenQA::Scheduler::Scheduler::job_get(99937);
@ret  = OpenQA::Scheduler::Scheduler::job_restart(99937);
$job2 = OpenQA::Scheduler::Scheduler::job_get(99937);

like($job2->{clone_id}, qr/\d+/, "clone is tracked");
delete $job1->{clone_id};
delete $job2->{clone_id};
is_deeply($job1, $job2, "done job unchanged after restart");

is(@ret, 1, "one job id returned");
$job2 = OpenQA::Scheduler::Scheduler::job_get($ret[0]);

isnt($job1->{id}, $job2->{id}, "new job has a different id");
is($job2->{state}, 'scheduled', "new job is scheduled");

$jobs = list_jobs();

is(@$jobs, @$current_jobs + 2, "two more job after restarting done job with chained child dependency");

$current_jobs = $jobs;

OpenQA::Scheduler::Scheduler::job_restart(99963);

$jobs = list_jobs();
is(@$jobs, @$current_jobs + 2, "two more job after restarting running job with parallel dependency");

$job1 = OpenQA::Scheduler::Scheduler::job_get(99963);
OpenQA::Scheduler::Scheduler::job_cancel(99963);
$job2 = OpenQA::Scheduler::Scheduler::job_get(99963);

is_deeply($job1, $job2, "running job unchanged after cancel");

my $job3 = OpenQA::Scheduler::Scheduler::job_get(99938)->{clone_id};
OpenQA::Scheduler::Scheduler::job_set_done(jobid => $job3, result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
$job3 = OpenQA::Scheduler::Scheduler::job_get($job3);
is($job3->{retry_avbl}, 3, "the retry counter setup ");
my $round1_id = OpenQA::Scheduler::Scheduler::job_duplicate((jobid => $job3->{id}, dup_type_auto => 1));
ok(defined $round1_id, "auto-duplicate works");
$job3 = OpenQA::Scheduler::Scheduler::job_get($round1_id);
is($job3->{retry_avbl}, 2, "the retry counter decreased");
# need to change state from scheduled
OpenQA::Scheduler::Scheduler::job_set_done(jobid => $round1_id, result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round2_id = OpenQA::Scheduler::Scheduler::job_duplicate((jobid => $round1_id, dup_type_auto => 1));
ok(defined $round2_id, "auto-duplicate works");
$job3 = OpenQA::Scheduler::Scheduler::job_get($round2_id);
is($job3->{retry_avbl}, 1, "the retry counter decreased");
# need to change state from scheduled
OpenQA::Scheduler::Scheduler::job_set_done(jobid => $round2_id, result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round3_id = OpenQA::Scheduler::Scheduler::job_duplicate((jobid => $round2_id, dup_type_auto => 1));
ok(defined $round3_id, "auto-duplicate works");
$job3 = OpenQA::Scheduler::Scheduler::job_get($round3_id);
is($job3->{retry_avbl}, 0, "the retry counter decreased");
# need to change state from scheduled
OpenQA::Scheduler::Scheduler::job_set_done(jobid => $round3_id, result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round4_id = OpenQA::Scheduler::Scheduler::job_duplicate((jobid => $round3_id, dup_type_auto => 1));
ok(!defined $round4_id, "no logner auto-duplicating");
# need to change state from scheduled
OpenQA::Scheduler::Scheduler::job_set_done(jobid => $round3_id, result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round5_id = OpenQA::Scheduler::Scheduler::job_duplicate(jobid => $round3_id);
ok(defined $round5_id, "manual-duplicate works");
$job3 = OpenQA::Scheduler::Scheduler::job_get($round5_id);
is($job3->{retry_avbl}, 1, "the retry counter increased");
