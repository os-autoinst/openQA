#!/usr/bin/env perl
# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Jobs::Constants;
use Test::Mojo;
use Test::Warnings ':report_warnings';


my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl 06-job_dependencies.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

# from fixtures
my $jobA = 99961;
my $jobB = 99963;
my $tokenA = 'token' . $jobA;
my $tokenB = 'token' . $jobB;

# mutex API is inaccessible without jobtoken auth
$t->post_ok('/api/v1/mutex', form => {name => 'test_lock'})->status_is(403);
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

$t->post_ok('/api/v1/mutex/test_lock')->status_is(400);    # missing action
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


#######################################
### helpers
my $last_worker_instance = 1;
my $b_prefix = '/api/v1/barrier';
my $m_prefix = '/api/v1/mutex';

sub job_create_with_worker {
    my ($test, $parent) = @_;
    my %settings = (
        DISTRI => 'Unicorn',
        FLAVOR => 'pink',
        VERSION => '42',
        BUILD => '666',
        ISO => 'whatever.iso',
        DESKTOP => 'DESKTOP',
        KVM => 'KVM',
        ISO_MAXSIZE => 1,
        MACHINE => 'RainbowPC',
        ARCH => 'x86_64',
        TEST => $test,
    );
    $settings{_PARALLEL_JOBS} = $parent if $parent;
    my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
    ok($job, "Job $test created with id " . $job->id);
    is($job->parents->single->parent_job_id, $parent, 'Job has correct parent') if $parent;
    my %worker = (
        cpu_modelname => 'Rainbow CPU',
        cpu_arch => 'x86_64',
        worker_class => 'qemu_x86_64,qemu_i686',
        cpu_opmode => '32-bit, 64-bit',
        mem_max => '4096',
        websocket_api_version => WEBSOCKET_API_VERSION,
        isotovideo_interface_version => WEBSOCKET_API_VERSION
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

#######################################
## Lock & unlock mutex on sibling jobs
my $jP = job_create_with_worker('testA');
my $jS1 = job_create_with_worker('testB', $jP);
my $jS2 = job_create_with_worker('testC', $jP);

# Happy path - create lock on sb1, lock & unlock on sb2
# Create lock on sibling 1
set_token_header($t->ua, 'token' . $jS1);
$t->post_ok($m_prefix, form => {name => 'sblock1'})->status_is(200);
$t->post_ok($m_prefix, form => {name => 'sblock2'})->status_is(200);
# Use lock from sibling 2
set_token_header($t->ua, 'token' . $jS2);
# Lock & check in DB
$t->post_ok($m_prefix . '/sblock1', form => {action => 'lock', where => $jS1})->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jS1, name => 'sblock1'});
is($res->locked_by, $jS2, 'mutex is locked');
# Unlock & check in DB
$t->post_ok($m_prefix . '/sblock1', form => {action => 'unlock', where => $jS1})->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jS1, name => 'sblock1'});
ok(!$res->locked_by, 'mutex is unlocked');

# Unhappy path
# Double unlock
$t->post_ok($m_prefix . '/sblock1', form => {action => 'unlock', where => $jS1})->status_is(200);
# Unlock nonexistent
$t->post_ok($m_prefix . '/nonexistent', form => {action => 'unlock', where => $jS1})->status_is(409);
# Unlock first, then lock
$t->post_ok($m_prefix . '/sblock2', form => {action => 'unlock', where => $jS1})->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jS1, name => 'sblock2'});
ok(!$res->locked_by, 'mutex is unlocked');
$t->post_ok($m_prefix . '/sblock2', form => {action => 'lock', where => $jS1})->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jS1, name => 'sblock2'});
is($res->locked_by, $jS2, 'mutex is locked');

#######################################
### barriers
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



sub test_barrier_destroy {

    my ($state, $test) = @_;
    # create barrier succeeds with 3 expected tasks
    my $jA = job_create_with_worker('testA');
    my $jB = job_create_with_worker('testB', $jA);
    my $jC = job_create_with_worker('testC', $jA);

    $test = eval "\$$test";
    set_token_header($t->ua, 'token' . $jA);
    $t->post_ok($b_prefix, form => {name => 'barrier2', tasks => 3},)->status_is(200);
    # barrier is not unlocked after one task
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(409);
    # barrier is not unlocked after two tasks
    set_token_header($t->ua, 'token' . $jB);
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);

    my $job = $schema->resultset('Jobs')->find($test)->update({result => $state});

    # barrier will be destroyed
    set_token_header($t->ua, 'token' . $jA);
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(410);
    # barrier is not there  for all jobs
    set_token_header($t->ua, 'token' . $jC);
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(410);
    set_token_header($t->ua, 'token' . $jA);
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(410);
    set_token_header($t->ua, 'token' . $jB);
    $t->post_ok($b_prefix . '/barrier2', form => {action => 'wait'})->status_is(410);
    return 1;
}

test_barrier_destroy($_, "jA")
  && test_barrier_destroy($_, "jB")
  && test_barrier_destroy($_, "jC")
  for OpenQA::Jobs::Constants::NOT_OK_RESULTS();


# create barrier succeeds with 3 expected tasks
$jA = job_create_with_worker('testA');
$jB = job_create_with_worker('testB', $jA);
$jC = job_create_with_worker('testC', $jA);
set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix, form => {name => 'barrier2', tasks => 3},)->status_is(200);
# barrier is not unlocked after one task
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);
# barrier is not unlocked after two tasks
set_token_header($t->ua, 'token' . $jB);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);

my $job = $schema->resultset('Jobs')->find($jB)->update({result => 'INVALIDRESULT'});

set_token_header($t->ua, 'token' . $jB);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);

set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);
# barrier is not there  for all jobs
set_token_header($t->ua, 'token' . $jC);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(200);


# create barrier succeeds with 3 expected tasks
$jA = job_create_with_worker('testA');
$jB = job_create_with_worker('testB', $jA);
$jC = job_create_with_worker('testC', $jA);

set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix, form => {name => 'barrier2', tasks => 3},)->status_is(200);
# barrier is not unlocked after one task
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);
# barrier is not unlocked after two tasks
set_token_header($t->ua, 'token' . $jB);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);

$schema->resultset('Jobs')->find($jB)->update({result => 'done'});

set_token_header($t->ua, 'token' . $jA);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(409);
# barrier is not there  for all jobs
set_token_header($t->ua, 'token' . $jC);
$t->post_ok($b_prefix . '/barrier2', form => {action => 'wait', check_dead_job => 1})->status_is(200);

# input validation
$t->post_ok($m_prefix)->status_is(400)->content_is('Erroneous parameters (name missing)');
$t->post_ok("$m_prefix/foo")->status_is(400)->content_is('Erroneous parameters (action missing)');
$t->post_ok($b_prefix => form => {tasks => 'abc'})->status_is(400)
  ->content_is('Erroneous parameters (name missing, tasks invalid)');
$t->post_ok("$b_prefix/foo" => form => {where => 'abc'})->status_is(400)
  ->content_is('Erroneous parameters (where invalid)');
$t->delete_ok("$b_prefix/foo" => form => {where => 'abc'})->status_is(400)
  ->content_is('Erroneous parameters (where invalid)');

done_testing();
