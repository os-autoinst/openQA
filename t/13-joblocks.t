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
use Test::More;
use Test::Mojo;

my $schema = OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA');

my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE => "RainbowPC",
    ARCH => 'x86_64'
);

# need some kind of dependency for children lock testing

my %settingsA = %settings;
my %settingsB = %settings;

$settingsA{JOBTOKEN} = 'tokenA';
$settingsA{TEST} = 'A';
$settingsB{JOBTOKEN} = 'tokenB';
$settingsB{TEST} = 'B';

my $jobA = OpenQA::Scheduler::job_create(\%settingsA);

$settingsB{_PARALLEL_JOBS} = [$jobA];
my $jobB = OpenQA::Scheduler::job_create(\%settingsB);


# mutex API is inaccesible without jobtoken auth
$t->post_ok('/api/v1/mutex/lock/test_lock')->status_is(403);
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(403);
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(403);

$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'tokenA');
    }
);
# try locking before mutex is created
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(409);

# create test mutex
$t->post_ok('/api/v1/mutex/lock/test_lock')->status_is(200);
## lock in DB
my $res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok($res, 'mutex is in database');
## mutex is not locked
ok(!$res->locked_by, 'mutex is not locked');

# lock mutex
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(200);
## mutex is locked
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
is($res->locked_by->id, $jobA, 'mutex is locked');
# try double lock
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(200);

$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'tokenB');
    }
);
# try to lock as another job
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(409);
# try to unlock as another job
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(409);

$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'tokenA');
    }
);

# unlock mutex
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(200);
## mutex unlocked in DB
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok(!$res->locked_by, 'mutex is unlocked');

# try to unlock & lock unlocked mutex as another job
$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'tokenB');
    }
);
# try double unlock
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(200);
## mutex remains unlocked in DB
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
ok(!$res->locked_by, 'mutex is unlocked');
# lock
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(200);
$res = $schema->resultset('JobLocks')->find({owner => $jobA, name => 'test_lock'});
is($res->locked_by->id, $jobB, 'mutex is locked');

done_testing();
