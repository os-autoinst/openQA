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
use FindBin;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd);
use OpenQA::Scheduler::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Utils;
use OpenQA::Test::Database;

use Test::More;
use Test::Warnings;
use Test::Output qw(stderr_like);

# create Test DBus bus and service for fake WebSockets call
my $ws = OpenQA::WebSockets->new;

my $schema = OpenQA::Test::Database->new->create();

sub list_jobs {
    [map { $_->to_hash() } $schema->resultset('Jobs')->all];
}

sub job_get_rs {
    my ($id) = @_;
    return $schema->resultset("Jobs")->find({id => $id});
}

sub job_get {
    my $job = job_get_rs(@_);
    return unless $job;
    return $job->to_hash;
}

ok($schema, "create database") || BAIL_OUT("failed to create database");

my $current_jobs = list_jobs();
ok(@$current_jobs, "have jobs");

my $job1 = job_get(99927);
is($job1->{state}, OpenQA::Schema::Result::Jobs::SCHEDULED, 'trying to duplicate scheduled job');
my $job = job_get_rs(99927)->auto_duplicate;
ok(!defined $job, "duplication rejected");

$job1 = job_get(99926);
is($job1->{state}, OpenQA::Schema::Result::Jobs::DONE, 'trying to duplicate done job');
$job = job_get_rs(99926)->auto_duplicate;
ok(defined $job, "duplication works");
isnt($job->id, $job1->{id}, 'clone id is different than original job id');

my $jobs = list_jobs();
is(@$jobs, @$current_jobs + 1, "one more job after duplicating one job");

$current_jobs = $jobs;

my $job2 = job_get($job->id);
is(delete $job2->{origin_id}, delete $job1->{id}, 'original job');
# delete the obviously different fields
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
is_deeply($job1, $job2, 'duplicated job equal');

my @ret = OpenQA::Scheduler::Scheduler::job_restart(99926);
is(@ret, 0, "no job ids returned");

$jobs = list_jobs();
is_deeply($jobs, $current_jobs, "jobs unchanged after restarting scheduled job");

$job1 = job_get(99927);
job_get_rs(99927)->cancel;
$job1 = job_get(99927);
is($job1->{state}, 'cancelled', "scheduled job cancelled after cancel");

$job1 = job_get(99937);
@ret  = OpenQA::Scheduler::Scheduler::job_restart(99937);
$job2 = job_get(99937);

like($job2->{clone_id}, qr/\d+/, "clone is tracked");
delete $job1->{clone_id};
delete $job2->{clone_id};
is_deeply($job1, $job2, "done job unchanged after restart");

is(@ret, 1, "one job id returned");
$job2 = job_get($ret[0]);

isnt($job1->{id}, $job2->{id}, "new job has a different id");
is($job2->{state}, 'scheduled', "new job is scheduled");

$jobs = list_jobs();

is(@$jobs, @$current_jobs + 2, "two more job after restarting done job with chained child dependency");

$current_jobs = $jobs;

OpenQA::Scheduler::Scheduler::job_restart(99963);

$jobs = list_jobs();
is(@$jobs, @$current_jobs + 2, "two more job after restarting running job with parallel dependency");

$job1 = job_get(99963);
job_get_rs(99963)->cancel;
$job2 = job_get(99963);

is_deeply($job1, $job2, "running job unchanged after cancel");

my $job3 = job_get(99938)->{clone_id};
job_get_rs($job3)->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
$job3 = job_get($job3);
is($job3->{retry_avbl}, 3, "the retry counter setup ");
my $round1 = job_get_rs($job3->{id})->auto_duplicate({dup_type_auto => 1});
ok(defined $round1, "auto-duplicate works");
$job3 = job_get($round1->id);
is($job3->{retry_avbl}, 2, "the retry counter decreased");
# need to change state from scheduled
$job3 = job_get($round1->id);
job_get_rs($job3->{id})->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
$round1->discard_changes;
my $round2 = $round1->auto_duplicate({dup_type_auto => 1});
ok(defined $round2, "auto-duplicate works");
$job3 = job_get($round2->id);
is($job3->{retry_avbl}, 1, "the retry counter decreased");
# need to change state from scheduled
job_get_rs($job3->{id})->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
$round2->discard_changes;
my $round3 = $round2->auto_duplicate({dup_type_auto => 1});
ok(defined $round3, "auto-duplicate works");
$job3 = job_get($round3->id);
is($job3->{retry_avbl}, 0, "the retry counter decreased");
# need to change state from scheduled
job_get_rs($job3->{id})->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round4_id;
stderr_like {
    $round4_id = job_get_rs($round3->id)->auto_duplicate({dup_type_auto => 1});
}
qr/Could not auto-duplicated! The job are auto-duplicated too many times/;
ok(!defined $round4_id, "no longer auto-duplicating");
# need to change state from scheduled
$job3 = job_get($round3->id);
job_get_rs($job3->{id})->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
my $round5 = job_get_rs($round3->id)->auto_duplicate;
ok(defined $round5, "manual-duplicate works");
$job3 = job_get($round5->id);
is($job3->{retry_avbl}, 1, "the retry counter increased");

done_testing;
