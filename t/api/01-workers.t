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
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');
# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret;

like(
    warning { $ret = $t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 1, backend => 'qemu'}) },
    qr/missing apisecret/
);
is($ret->tx->res->code, 403, "register worker without API key fails");

$t->ua(OpenQA::Client->new(api => 'testapi')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$ret = $t->get_ok('/api/v1/workers');
ok($ret->tx->success, 'listing workers works');
is(ref $ret->tx->res->json, 'HASH', 'workers returned hash');
is_deeply(
    $ret->tx->res->json,
    {
        workers => [
            {
                id         => 1,
                instance   => 1,
                connected  => 0,
                jobid      => 99963,
                host       => 'localhost',
                properties => {'JOBTOKEN' => 'token99963'},
                status     => 'running'
            },
            {
                'jobid'      => 99961,
                'properties' => {
                    'JOBTOKEN' => 'token99961'
                },
                'id'        => 2,
                'connected' => 0,
                'status'    => 'running',
                'host'      => 'remotehost',
                'instance'  => 1
            }]
    },
    'worker present'
);

my $worker_caps = {
    host     => 'localhost',
    instance => 1,
};

$ret = $t->post_ok('/api/v1/workers', form => $worker_caps);
is($ret->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{cpu_arch} = 'foo';
$ret = $t->post_ok('/api/v1/workers', form => $worker_caps);
is($ret->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{mem_max} = '4711';
$ret = $t->post_ok('/api/v1/workers', form => $worker_caps);
is($ret->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{worker_class} = 'bar';

$ret = $t->post_ok('/api/v1/workers', form => $worker_caps);
is($ret->tx->res->code,       200, "register existing worker with token");
is($ret->tx->res->json->{id}, 1,   "worker id is 1");

$worker_caps->{instance} = 42;
$ret = $t->post_ok('/api/v1/workers', form => $worker_caps);
is($ret->tx->res->code,       200, "register new worker");
is($ret->tx->res->json->{id}, 3,   "new worker id is 3");


done_testing();
