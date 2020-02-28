#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
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

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::Test::Utils 'embed_server_for_testing';
use OpenQA::Client;
use OpenQA::WebSockets::Client;
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD WEBSOCKET_API_VERSION);
use OpenQA::Jobs::Constants;
use Date::Format 'time2str';

my $test_case = OpenQA::Test::Case->new;
my $schema    = $test_case->init_data;
my $jobs      = $schema->resultset('Jobs');
my $workers   = $schema->resultset('Workers');

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client      => OpenQA::WebSockets::Client->singleton,
);

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

my @workers = (
    {
        id         => 1,
        instance   => 1,
        connected  => 1,                              # deprecated
        websocket  => 1,                              # deprecated
        error      => undef,
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
        connected => 1,              # deprecated
        websocket => 1,              # deprecated
        error     => undef,
        alive     => 1,
        status    => 'running',
        host      => 'remotehost',
        instance  => 1
    });

$t->get_ok('/api/v1/workers?live=1');
ok(!$t->tx->error, 'listing workers works');
is(ref $t->tx->res->json, 'HASH', 'workers returned hash');
is_deeply(
    $t->tx->res->json,
    {
        workers => \@workers,
    },
    'worker present'
) or diag explain $t->tx->res->json;

# note: The live flag is deprecated and makes no difference anymore (not padding the flag
#       is as good as passing it). For compatibility "connected" and "websocket" are still
#       provided.

$_->{websocket} = 0 for @workers;

$t->get_ok('/api/v1/workers');
ok(!$t->tx->error, 'listing workers works');
is(ref $t->tx->res->json, 'HASH', 'workers returned hash');
is_deeply(
    $t->tx->res->json,
    {
        workers => \@workers,
    },
    'worker present'
) or diag explain $t->tx->res->json;


my %registration_params = (
    host     => 'localhost',
    instance => 1,
);

$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$registration_params{cpu_arch} = 'foo';
$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$registration_params{mem_max} = '4711';
$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code, 400, "worker with missing parameters refused");

$registration_params{worker_class} = 'bar';

$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code, 426, "worker informed to upgrade");
$registration_params{websocket_api_version} = WEBSOCKET_API_VERSION;

$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code,       200, "register existing worker with token");
is($t->tx->res->json->{id}, 1,   "worker id is 1");

$registration_params{instance} = 42;
$t->post_ok('/api/v1/workers', form => \%registration_params);
is($t->tx->res->code,       200, "register new worker");
is($t->tx->res->json->{id}, 3,   "new worker id is 3");

subtest 'incompleting previous job on worker registration' => sub {
    # assume the worker runs some job
    my $running_job_id = 99961;
    my $worker         = $workers->search({job_id => $running_job_id})->first;
    my $worker_id      = $worker->id;

    my %registration_params = (
        host                  => 'remotehost',
        instance              => 1,
        job_id                => $running_job_id,
        cpu_arch              => 'aarch64',
        mem_max               => 2048,
        worker_class          => 'foo',
        websocket_api_version => WEBSOCKET_API_VERSION,
    );

    is($jobs->find($running_job_id)->state, RUNNING, 'job is running in the first place');

    subtest 'previous job not incompleted when still being worked on' => sub {
        $t->post_ok('/api/v1/workers', form => \%registration_params);
        is($t->tx->res->code,                   200,        'register existing worker passing job ID');
        is($t->tx->res->json->{id},             $worker_id, 'worker ID returned');
        is($jobs->find($running_job_id)->state, RUNNING,    'assigned job still running');
    };

    subtest 'previous job incompleted when worker doing something else' => sub {
        delete $registration_params{job_id};
        $t->post_ok('/api/v1/workers', form => \%registration_params);
        is($t->tx->res->code,       200,        'register existing worker passing no job ID');
        is($t->tx->res->json->{id}, $worker_id, 'worker ID returned');
        my $incomplete_job = $jobs->find($running_job_id);
        is($incomplete_job->state, DONE, 'assigned job set to done');
        ok($incomplete_job->result eq INCOMPLETE || $incomplete_job->result eq PARALLEL_RESTARTED,
            'assigned job considered incomplete or parallel restarted')
          or diag explain 'actual job result: ' . $incomplete_job->result;
    };
};

subtest 'delete offline worker' => sub {
    my $offline_worker_id = 9;
    $workers->create(
        {
            id        => $offline_worker_id,
            host      => 'offline_test',
            instance  => 5,
            t_updated => time2str('%Y-%m-%d %H:%M:%S', time - WORKERS_CHECKER_THRESHOLD - 1, 'UTC'),
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
