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
}

use strict;
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Scheduler;
use Test::More 'no_plan';
use Test::Mojo;
use Test::Warnings;

# create Test DBus bus and service for fake WebSockets call
my $ipc = OpenQA::IPC->ipc('', 1);
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
is($res->locked_by->id, $jobA, 'mutex is locked');
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
is($res->locked_by->id, $jobB, 'mutex is locked');
