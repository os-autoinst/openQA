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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# get resultsets
my $db      = $t->app->schema;
my $workers = $db->resultset('Workers');
my $jobs    = $db->resultset('Jobs');

$db->txn_begin;

subtest 'reschedule assigned jobs' => sub {
    my $worker_1 = $workers->find({host => 'localhost', instance => 1});

    # assume the jobs 99961, 99963 and 99937 are assigned to the worker and 99961 is the current job
    $workers->search({})->update({job_id => undef});
    $worker_1->update({job_id => 99961});
    $jobs->find($_)->update({state => ASSIGNED, assigned_worker_id => $worker_1->id}) for (99961, 99963);
    $jobs->find(99937)->update({state => PASSED, assigned_worker_id => $worker_1->id});

    $worker_1->reschedule_assigned_jobs;
    $worker_1->discard_changes;

    is($worker_1->job_id, undef, 'current job has been un-assigned');
    for my $job_id ((99961, 99963)) {
        my $job = $jobs->find($job_id);
        is($job->state,              SCHEDULED, "job $job_id is scheduled again");
        is($job->assigned_worker_id, undef,     "job $job_id has no worker assigned anymore");
    }
    my $passed_job = $jobs->find(99937);
    is($passed_job->state,              PASSED,        'passed job not affected');
    is($passed_job->assigned_worker_id, $worker_1->id, 'passed job still associated with worker');
};

$db->txn_rollback;

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
