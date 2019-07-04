#! /usr/bin/perl

# Copyright (C) 2014-2017 SUSE LLC
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

use Mojo::Base -strict;

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::WebSockets::Client;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use Date::Format 'time2str';

OpenQA::Test::Case->new->init_data;
OpenQA::WebSockets::Client->singleton->embed_server_for_testing;

my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 1, backend => 'qemu'});
is($t->tx->res->code, 403, 'register worker without API key fails (403)');
is_deeply(
    $t->tx->res->json,
    {
        error        => 'no api key',
        error_status => 403,
    },
    'register worker without API key fails (error message)'
);

$t->ua(OpenQA::Client->new(api => 'testapi')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $workers = [
    {
        id         => 1,
        instance   => 1,
        connected  => 0,
        error      => undef,
        websocket  => 0,
        alive      => 1,
        jobid      => 99963,
        host       => 'localhost',
        properties => {'JOBTOKEN' => 'token99963'},
        status     => 'running'
    },
    {
        jobid      => 99961,
        properties => {
            JOBTOKEN => 'token99961'
        },
        id        => 2,
        connected => 0,
        error     => undef,
        websocket => 0,
        alive     => 1,
        status    => 'running',
        host      => 'remotehost',
        instance  => 1
    }];

$t->get_ok('/api/v1/workers?live=1');
ok(!$t->tx->error, 'listing workers works');
is(ref $t->tx->res->json, 'HASH', 'workers returned hash');
is_deeply(
    $t->tx->res->json,
    {
        workers => $workers,
    },
    'worker present'
) or diag explain $t->tx->res->json;

$workers->[0]->{connected} = 1;
$workers->[1]->{connected} = 1;

$t->get_ok('/api/v1/workers');
ok(!$t->tx->error, 'listing workers works');
is(ref $t->tx->res->json, 'HASH', 'workers returned hash');
is_deeply(
    $t->tx->res->json,
    {
        workers => $workers,
    },
    'worker present'
) or diag explain $t->tx->res->json;


my $worker_caps = {
    host     => 'localhost',
    instance => 1,
};

$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{cpu_arch} = 'foo';
$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{mem_max} = '4711';
$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$worker_caps->{worker_class} = 'bar';

$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code, 426, "worker informed to upgrade");
$worker_caps->{websocket_api_version} = WEBSOCKET_API_VERSION;

$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code,       200, "register existing worker with token");
is($t->tx->res->json->{id}, 1,   "worker id is 1");

$worker_caps->{instance} = 42;
$t->post_ok('/api/v1/workers', form => $worker_caps);
is($t->tx->res->code,       200, "register new worker");
is($t->tx->res->json->{id}, 3,   "new worker id is 3");

subtest 'delete offline worker' => sub {
    my $offline_worker_id = 9;
    my $database_workers  = $t->app->schema->resultset("Workers");
    $database_workers->create(
        {
            id        => $offline_worker_id,
            host      => 'offline_test',
            instance  => 5,
            t_updated => time2str('%Y-%m-%d %H:%M:%S', time - 1200, 'UTC'),
        });

    $t->delete_ok("/api/v1/workers/$offline_worker_id")->status_is(200, "delete offline worker successfully.");

    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'worker_delete'),
        {
            id   => $offline_worker_id,
            name => "offline_test:5"
        },
        "Delete worker was logged correctly."
    );

    $t->delete_ok("/api/v1/workers/99")->status_is(404, "The offline worker not found.");

    $t->delete_ok("/api/v1/workers/1")->status_is(400, "The worker status is not offline.");
};

done_testing();
