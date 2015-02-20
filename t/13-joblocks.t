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

# mutex API is inaccesible without jobtoken auth
$t->post_ok('/api/v1/mutex/lock/test_lock')->status_is(403);
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(403);
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(403);

$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'token99963');
    }
);
# try locking before mutex is created
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(409);

# create test mutex
$t->post_ok('/api/v1/mutex/lock/test_lock')->status_is(200);
## lock in DB
my $res = $schema->resultset('JobLocks')->find({owner => 99963, name => 'test_lock'});
ok($res, 'mutex is in database');
## mutex is not locked
ok(!$res->locked_by, 'mutex is not locked');

# lock mutex
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(200);
## mutex is locked
$res = $schema->resultset('JobLocks')->find({owner => 99963, name => 'test_lock'});
ok($res->locked_by, 'mutex is locked');
# try double lock
$t->get_ok('/api/v1/mutex/lock/test_lock')->status_is(200);

$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'token99961');
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
        $tx->req->headers->add('X-API-JobToken' => 'token99963');
    }
);

# unlock mutex
$t->get_ok('/api/v1/mutex/unlock/test_lock')->status_is(200);
## mutex unlocked in DB
$res = $schema->resultset('JobLocks')->find({owner => 99963, name => 'test_lock'});
ok(!$res->locked_by, 'mutex is unlocked');

done_testing();
