#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use Mojo::URL;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use OpenQA::Test::Utils 'embed_server_for_testing';
use OpenQA::Client;
use OpenQA::WebSockets::Client;
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT DB_TIMESTAMP_ACCURACY WEBSOCKET_API_VERSION);
use OpenQA::Jobs::Constants;
use Date::Format 'time2str';

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $jobs = $schema->resultset('Jobs');
my $workers = $schema->resultset('Workers');

# assume all workers are online
$workers->update({t_seen => time2str('%Y-%m-%d %H:%M:%S', time + 60, 'UTC')});

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client => OpenQA::WebSockets::Client->singleton,
);

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->post_ok('/api/v1/workers', form => {host => 'localhost', instance => 1, backend => 'qemu'})
  ->status_is(403, 'register worker without API key fails (403)')->json_is(
    '' => {
        error => 'no api key',
        error_status => 403,
    },
    'register worker without API key fails (error message)'
  );

$t->ua(OpenQA::Client->new(api => 'testapi')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my @workers = (
    {
        id => 1,
        instance => 1,
        connected => 1,    # deprecated
        websocket => 1,    # deprecated
        error => undef,
        alive => 1,
        jobid => 99963,
        host => 'localhost',
        properties => {'JOBTOKEN' => 'token99963'},
        status => 'running'
    },
    {
        jobid => 99961,
        properties => {
            JOBTOKEN => 'token99961'
        },
        id => 2,
        connected => 1,    # deprecated
        websocket => 1,    # deprecated
        error => undef,
        alive => 1,
        status => 'running',
        host => 'remotehost',
        instance => 1
    });

$t->get_ok('/api/v1/workers?live=1')
  ->json_is('' => {workers => \@workers}, 'workers present with deprecated live flag');
diag explain $t->tx->res->json unless $t->success;
$_->{websocket} = 0 for @workers;
$t->get_ok('/api/v1/workers')->json_is('' => {workers => \@workers}, "workers present with deprecated websocket flag");
diag explain $t->tx->res->json unless $t->success;

my %registration_params = (
    host => 'localhost',
    instance => 1,
);
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(400, 'worker with missing parameters refused')
  ->json_is('/error' => 'Erroneous parameters (cpu_arch missing, mem_max missing, worker_class missing)');

$registration_params{cpu_arch} = 'foo';
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(400, 'worker with missing parameters refused')
  ->json_is('/error' => 'Erroneous parameters (mem_max missing, worker_class missing)');

$registration_params{mem_max} = '4711';
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(400, 'worker with missing parameters refused')
  ->json_is('/error' => 'Erroneous parameters (worker_class missing)');

$registration_params{worker_class} = 'bar';
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(426, 'worker informed to upgrade');

$registration_params{websocket_api_version} = WEBSOCKET_API_VERSION;
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(200, 'register existing worker with token')
  ->json_is('/id' => 1, 'worker id is 1');
diag explain $t->tx->res->json unless $t->success;

$registration_params{instance} = 42;
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(200, 'register new worker')
  ->json_is('/id' => 3, 'new worker id is 3');
diag explain $t->tx->res->json unless $t->success;
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'worker_register'),
    {
        id => $t->tx->res->json->{id},
        host => 'localhost',
        instance => 42,
    },
    'worker event was logged correctly'
);

subtest 'incompleting previous job on worker registration' => sub {
    # assume the worker runs some job
    my $running_job_id = 99961;
    my $worker = $workers->search({job_id => $running_job_id})->first;
    my $worker_id = $worker->id;

    my %registration_params = (
        host => 'remotehost',
        instance => 1,
        job_id => $running_job_id,
        cpu_arch => 'aarch64',
        mem_max => 2048,
        worker_class => 'foo',
        websocket_api_version => WEBSOCKET_API_VERSION,
    );

    is($jobs->find($running_job_id)->state, RUNNING, 'job is running in the first place');

    subtest 'previous job not incompleted when still being worked on' => sub {
        $t->post_ok('/api/v1/workers', form => \%registration_params)
          ->status_is(200, 'register existing worker passing job ID')
          ->json_is('/id' => $worker_id, 'worker ID returned');
        return diag explain $t->tx->res->json unless $t->success;
        is($jobs->find($running_job_id)->state, RUNNING, 'assigned job still running');
    };

    subtest 'previous job incompleted when worker doing something else' => sub {
        delete $registration_params{job_id};
        $t->post_ok('/api/v1/workers', form => \%registration_params)
          ->status_is(200, 'register existing worker passing no job ID')
          ->json_is('/id' => $worker_id, 'worker ID returned');
        return diag explain $t->tx->res->json unless $t->success;
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
            id => $offline_worker_id,
            host => 'offline_test',
            instance => 5,
            t_seen => time2str('%Y-%m-%d %H:%M:%S', time - DEFAULT_WORKER_TIMEOUT - DB_TIMESTAMP_ACCURACY, 'UTC'),
        });
    $t->delete_ok("/api/v1/workers/$offline_worker_id")->status_is(200, 'offline worker deleted');

    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'worker_delete'),
        {
            id => $offline_worker_id,
            name => "offline_test:5"
        },
        "Delete worker was logged correctly."
    );

    $t->delete_ok('/api/v1/workers/99')->status_is(404, 'worker not found');
    $t->delete_ok('/api/v1/workers/1')->status_is(400, 'deleting online worker prevented');
};

done_testing();
