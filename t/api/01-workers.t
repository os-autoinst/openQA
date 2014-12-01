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
use Test::More;
use Test::Mojo;
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::API::V1::Client;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');
# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::API::V1::Client->new->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret;

$ret = $t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 1, backend => 'qemu' });
is($ret->tx->res->code, 403, "register worker without API key fails");

$t->ua(OpenQA::API::V1::Client->new(api => 'testapi')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$ret = $t->get_ok('/api/v1/workers');
ok($ret->tx->success, 'listing workers works');
is(ref $ret->tx->res->json, 'HASH', 'workers returned hash');
# just a random check that the structure is sane
is($ret->tx->res->json->{workers}->[1]->{host}, 'localhost', 'worker present');

$ret = $t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 1, backend => 'qemu' });
is($ret->tx->res->code, 200, "register existing worker with token");
is($ret->tx->res->json->{id}, 1, "worker id is 1");

$ret = $t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 42, backend => 'qemu' });
is($ret->tx->res->code, 200, "register new worker");
is($ret->tx->res->json->{id}, 2, "new worker id is 2");

done_testing();
