#!/usr/bin/env perl -w

# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Scheduler;
use Test::More;
use Test::Mojo;
use Test::Warnings;

# create Test DBus bus and service for fake WebSockets call
my $sh = OpenQA::Scheduler->new;

my $schema = OpenQA::Test::Database->new->create();
my $t      = Test::Mojo->new('OpenQA::WebAPI');

# from fixtures
my $jobA   = 99961;
my $jobB   = 99963;
my $tokenA = 'token' . $jobA;
my $tokenB = 'token' . $jobB;

# mutex API is inaccesible without jobtoken auth
$t->post_ok('/api/v1/mutex',           form => {name   => 'test_lock'})->status_is(403);
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(403);
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'unlock'})->status_is(403);

$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $tokenA);
    });
# try locking before mutex is created
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(409);

$t->post_ok('/api/v1/mutex')->status_is(400);    # missing name
$t->post_ok('/api/v1/mutex', form => {name => 'a/b'})->status_is(400);    # invalid name

# create test mutex
$t->post_ok('/api/v1/mutex', form => {name => 'test_lock'})->status_is(200);
## lock in DB
my $res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok($res, 'mutex is in database');
## mutex is not locked
ok(!$res->locked_by, 'mutex is not locked');

$t->post_ok('/api/v1/mutex/test_lock')->status_is(400);                   # missing action
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'invalid'})->status_is(400);    # invalid action

# lock mutex
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(200);
## mutex is locked
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
is($res->locked_by, $jobA, 'mutex is locked');
# try double lock
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(200);

$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $tokenB);
    });
# try to lock as another job
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(409);
# try to unlock as another job
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'unlock'})->status_is(409);

$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $tokenA);
    });

# unlock mutex
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'unlock'})->status_is(200);
## mutex unlocked in DB
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok(!$res->locked_by, 'mutex is unlocked');

# try to unlock & lock unlocked mutex as another job
$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => $tokenB);
    });
# try double unlock
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'unlock'})->status_is(200);
## mutex remains unlocked in DB
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok(!$res->locked_by, 'mutex is unlocked');
# lock
$t->post_ok('/api/v1/mutex/test_lock', form => {action => 'lock'})->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
is($res->locked_by, $jobB, 'mutex is locked');

### barriers
my $last_worker_instance = 1;
my $b_prefix             = '/api/v1/barrier';

sub job_create_with_worker {
    my ($test, $parent) = @_;
    my %settings = (
        DISTRI      => 'Unicorn',
        FLAVOR      => 'pink',
        VERSION     => '42',
        BUILD       => '666',
        ISO         => 'whatever.iso',
        DESKTOP     => 'DESKTOP',
        KVM         => 'KVM',
        ISO_MAXSIZE => 1,
        MACHINE     => 'RainbowPC',
        ARCH        => 'x86_64',
        TEST        => $test,
    );
    $settings{_PARALLEL_JOBS} = $parent if $parent;
    my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
    ok($job, "Job $test created with id " . $job->id);
    is($job->parents->single->parent_job_id, $parent, 'Job has correct parent') if $parent;
    my %worker = (
        cpu_modelname => 'Rainbow CPU',
        cpu_arch      => 'x86_64',
        worker_class  => 'qemu_x86_64,qemu_i686',
        cpu_opmode    => '32-bit, 64-bit',
        mem_max       => '4096'
    );

    use OpenQA::WebAPI::Controller::API::V1::Worker;
    my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;
    my $w_id = $c->_register($schema, "host", $last_worker_instance, \%worker);
    ok($w_id, "Worker instance $last_worker_instance created");
    $last_worker_instance++;

    #assign worker to the job, create job token
    my $worker = $schema->resultset('Workers')->find($w_id);
    $worker->job($job);
    $worker->update;
    $worker->set_property(JOBTOKEN => 'token' . $job->id);
    return $job->id;
}

sub set_token_header {
    my ($ua, $token) = @_;
    $ua->unsubscribe('start');
    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->add('X-API-JobToken' => $token);
        });
}

# create jobs we'll use
my $jid = job_create_with_worker('test');

# create barrier without job_id fails with 403 - forbidden
$t->ua->unsubscribe('start');
$t->post_ok($b_prefix)->status_is(403);
set_token_header($t->ua, 'token' . $jid);
# create barrier without name fails with 400 - wrong request
$t->post_ok($b_prefix)->status_is(400);
# create barrier without number of expected tasks fails
$t->post_ok($b_prefix, form => {name => 'barrier1'})->status_is(400);
# create barrier succeeds with 1 expected task
$t->post_ok($b_prefix, form => {name => 'barrier1', tasks => 1},)->status_is(200);
# barrier is unlocked after one task
$t->post_ok($b_prefix . '/barrier1', form => {action => 'wait'})->status_is(200);
# barrier is still unlocked for the same task
$t->post_ok($b_prefix . '/barrier1', form => {action => 'wait'})->status_is(200);

# create barrier succeeds with 3 expected tasks
my $jA = job_create_with_worker('testA');
my $jB = job_create_with_worker('testB', $jA);
my $jC = job_create_with_worker('testC', $jA);
set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix, form => {name => 'barrier2', tasks => 3},)->status_is(200);
# barrier is not unlocked after one task
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(409);
# barrier is not unlocked after two tasks
set_token_header($t->ua, 'token' . $jB);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(409);
# barrier is not unlocked after trying already tried task
set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(409);
# barrier is unlocked after three tasks
set_token_header($t->ua, 'token' . $jC);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(200);
# barrier is unlocked for task one and two
set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(200);
set_token_header($t->ua, 'token' . $jB);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(200);

# test deletes
$res = $schema->resultset('JobLocks')->find({owner => $jid, name => 'barrier1'});
ok($res, 'barrier1 is present');
$res = $schema->resultset('JobLocks')->find({owner => $jA, name => 'barrier2'});
ok($res, 'barrier2 is present');
# can not delete without barrier name
$t->delete_ok($b_prefix)->status_is(404);
# delete barrier2 and check it was removed
$t->delete_ok($b_prefix . '/barrier2')->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jA, name => 'barrier2'});
ok(!$res, 'barrier2 removed');
# can not delete others barrier - status is fine, but barrier is still there
$t->delete_ok($b_prefix . '/barrier1')->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jid, name => 'barrier1'});
ok($res, 'barrier1 is still there');
# can not delete without jobtoken
$t->ua->unsubscribe('start');
$t->delete_ok($b_prefix . '/barrier1')->status_is(403);

done_testing();
