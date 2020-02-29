#!/usr/bin/env perl

# Copyright (C) 2019-2020 SUSE LLC
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# get resultsets
my $db      = $t->app->schema;
my $workers = $db->resultset('Workers');
my $jobs    = $db->resultset('Jobs');

subtest 'delete job which is currently assigned to worker' => sub {
    my $worker_1        = $workers->find({host => 'localhost', instance => 1});
    my $job_of_worker_1 = $worker_1->job;
    is($job_of_worker_1->id, 99963, 'job 99963 belongs to worker 1 as specified in fixtures');

    $job_of_worker_1->delete;

    $worker_1 = $workers->find({host => 'localhost', instance => 1});
    ok($worker_1, 'worker 1 still exists')
      and is($worker_1->job, undef, 'job has been unassigned');
};

subtest 'delete job from worker history' => sub {
    my $worker_1 = $workers->find({host => 'localhost', instance => 1});
    my $job      = $jobs->find(99926);
    $job->update({assigned_worker_id => $worker_1->id});
    is_deeply([map { $_->id } $worker_1->previous_jobs->all], [99926], 'previous job assigned');

    $job->delete;
    $worker_1 = $workers->find({host => 'localhost', instance => 1});
    ok($worker_1, 'worker 1 still exists')
      and is_deeply([map { $_->id } $worker_1->previous_jobs->all], [], 'previous jobs empty again');
};

done_testing();
