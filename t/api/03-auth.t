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
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More tests => 14;
use Test::Mojo;
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::API::V1::Client;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');
# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::API::V1::Client->new()->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret;

# Access without API key is denied
$ret = $t->get_ok('/api/v1/workers')->status_is(403);

# Valid key with no expiration date works
$t->ua->key('PERCIVALKEY02');
$t->ua->secret('PERCIVALSECRET02');
$ret = $t->get_ok('/api/v1/workers')->status_is(200);

# But only with the right secret
$t->ua->secret('PERCIVALNOSECRET');
$ret = $t->get_ok('/api/v1/workers')->status_is(403);

# Keys that are still valid also work
$t->ua->key('PERCIVALKEY01');
$t->ua->secret('PERCIVALSECRET01');
$ret = $t->get_ok('/api/v1/workers')->status_is(200);

# But expired ones don't
$t->ua->key('EXPIREDKEY01');
$t->ua->secret('WHOCARESAFTERALL');
$ret = $t->get_ok('/api/v1/workers')->status_is(403);

# Of course, non-existent keys fail
$t->ua->key('INVENTEDKEY01');
$ret = $t->get_ok('/api/v1/workers')->status_is(403);

# Valid keys are rejected if the associated user is not operator
$t->ua->key('LANCELOTKEY01');
$t->ua->secret('MANYPEOPLEKNOW');
$ret = $t->get_ok('/api/v1/workers')->status_is(403);

done_testing();
