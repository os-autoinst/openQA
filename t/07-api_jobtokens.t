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

OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA');

# test jobtoken login is possible with correct jobtoken
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'token99963');
    });
$t->get_ok('/api/v1/whoami')->status_is(200)->json_is({'id' => 99963});

# test jobtoken login is not possible with wrong jobtoken
$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'wrongtoken');
    });
$t->get_ok('/api/v1/whoami')->status_is(403);

# and without jobtoken
$t->ua->unsubscribe('start');
$t->get_ok('/api/v1/whoami')->status_is(403);

done_testing();
