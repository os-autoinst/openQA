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
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Net::DBus;

use Test::More;

OpenQA::Test::Database->new->create();
# create Test DBus bus and service for fake WebSockets and Scheduler calls
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

my $new_job_id = OpenQA::Scheduler::job_duplicate(jobid => 99963);
ok($new_job_id, "got new job id");

my $job = OpenQA::Scheduler::job_get($new_job_id);
is($job->{state}, 'scheduled', "new job is scheduled");

$job = OpenQA::Scheduler::job_get(99963);
is($job->{state}, 'running', "old job is running");

sub lj {
    return unless $ENV{HARNESS_IS_VERBOSE};
    my $jobs = query_jobs();
    for my $j (@$jobs) {
        printf "%d %-10s %s\n", $j->id, $j->state, $j->name;
    }
}

lj;

my $ret = OpenQA::Scheduler::job_cancel({DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'x86_64'});
is($ret, 2, "two jobs cancelled by hash");

$job = OpenQA::Scheduler::job_get($new_job_id);

lj;

$job = OpenQA::Scheduler::job_get($new_job_id);
is($job->{state}, 'cancelled', "new job is cancelled");

$job = OpenQA::Scheduler::job_get(99963);
is($job->{state}, 'running', "old job still running");

$job = OpenQA::Scheduler::job_get(99928);
is($job->{state}, 'scheduled', "unrelated job 99928 still scheduled");
$job = OpenQA::Scheduler::job_get(99927);
is($job->{state}, 'scheduled', "unrelated job 99927 still scheduled");

$ret = OpenQA::Scheduler::job_cancel(99928);
is($ret, 1, "one job cancelled by id");

$job = OpenQA::Scheduler::job_get(99928);
is($job->{state}, 'cancelled', "job 99928 cancelled");
$job = OpenQA::Scheduler::job_get(99927);
is($job->{state}, 'scheduled', "unrelated job 99927 still scheduled");


$new_job_id = OpenQA::Scheduler::job_duplicate(jobid => 99981);
ok($new_job_id, "duplicate new job for iso test");

$job = OpenQA::Scheduler::job_get($new_job_id);
is($job->{state}, 'scheduled', "new job is scheduled");

lj;

$ret = OpenQA::Scheduler::job_cancel('openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso');
is($ret, 1, "one job cancelled by iso");

$job = OpenQA::Scheduler::job_get(99927);
is($job->{state}, 'scheduled', "unrelated job 99927 still scheduled");

done_testing();
