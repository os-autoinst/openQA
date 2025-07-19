#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use Test::Output qw(combined_like);
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

$t->get_ok('/api/v1/workers')->status_is(200, 'listing of all workers');
$t->json_is('' => {workers => \@workers}, 'workers present with deprecated websocket flag');
always_explain $t->tx->res->json unless $t->success;

$t->get_ok('/api/v1/workers/2')->status_is(200, 'info for existing individual worker');
$t->json_is('' => {worker => $workers[1]}, 'info for correct worker returned');
$t->get_ok('/api/v1/workers/3')->status_is(404, 'no info for non-existing worker');

my %worker_key = (host => 'localhost', instance => 1);
my %registration_params = %worker_key;
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

$workers->find(\%worker_key)->update({error => 'cache not available'});
$registration_params{websocket_api_version} = WEBSOCKET_API_VERSION;
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(200, 'register existing worker with token')
  ->json_is('/id' => 1, 'worker id is 1');
always_explain $t->tx->res->json unless $t->success;
is $workers->find(\%worker_key)->error, undef, 'possibly still present error from previous connection cleaned';

$registration_params{instance} = 42;
$t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(200, 'register new worker')
  ->json_is('/id' => 3, 'new worker id is 3');
always_explain $t->tx->res->json unless $t->success;
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
    my $worker_id = $workers->find({job_id => $running_job_id})->id;

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
        return always_explain $t->tx->res->json unless $t->success;
        is($jobs->find($running_job_id)->state, RUNNING, 'assigned job still running');
    };

    my $expected_breakage = '';
    my $expected_warning = qr//;
    my $test_registration = sub {
        $schema->txn_begin;
        combined_like sub { $t->post_ok('/api/v1/workers', form => \%registration_params) },
          $expected_warning, 'expected warning logged';
        $t->status_is(200, 'register existing worker passing no job ID');
        $t->json_is('/id' => $worker_id, 'worker ID returned');
        always_explain $t->tx->res->json unless $t->success;
        return $schema->txn_rollback if $expected_breakage eq 'worker';
        is $workers->find($worker_id)->job_id, undef, 'worker has no longer an assigned job';
        return $schema->txn_rollback if $expected_breakage eq 'job';
        my $incomplete_job = $jobs->find($running_job_id);
        is $incomplete_job->state, DONE, 'assigned job set to done';
        ok $incomplete_job->result eq INCOMPLETE || $incomplete_job->result eq PARALLEL_RESTARTED,
          'assigned job considered incomplete or parallel restarted'
          or always_explain 'actual job result: ' . $incomplete_job->result;
        $schema->txn_rollback;
    };

    subtest 'previous job incompleted when worker doing something else' => sub {
        delete $registration_params{job_id};

        subtest 'no errors occurred' => $test_registration;

        # test the worst case where workers will end up stuck with a job
        # note: This is not supposed to happen in production as errors are now supposed to be caught
        #       earlier by the cases tested in further subtests. However, this warning turned out to
        #       be useful when investigating problems so we should keep it and have this test.
        my $mock = Test::MockModule->new('OpenQA::WebAPI::Controller::API::V1::Worker');
        $mock->redefine(_incomplete_previous_job => sub { die 'foo1' });
        $expected_breakage = 'worker';
        $expected_warning = qr/Unable to incomplete.*reschedule.*abandoned by worker 2: foo1/;
        subtest 'incompleting previous job fails' => $test_registration;

        # test that everything else works as expected despite failing duplication
        $mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
        $mock->redefine(auto_duplicate => sub { die 'foo2' });
        $expected_breakage = '';
        $expected_warning = qr/Unable to duplicate job.*abandoned by worker remotehost:1: foo2/;
        subtest 'failure when duplicating job does not prevent anything else' => $test_registration;

        # test that when we cannot set the job to done the worker is at least freed from its job
        # note: It is very important to free the worker from its job as it would otherwise be stuck
        #       forever. The jobs seem to be mostly cancelled by obsoletion in practices anyway and
        #       can also be cancelled manually by users if needed.
        $mock->unmock('auto_duplicate');
        $mock->redefine(done => sub { die 'foo3' });
        $expected_breakage = 'job';
        $expected_warning = qr/Unable to incomplete job.*abandoned by worker remotehost:1: foo3/;
        subtest 'worker still freed from its job, even if job cannot be set done' => $test_registration;

        # test that failures when reading results (e.g. for carry over) are not preventing anything else to happen
        $mock = Test::MockModule->new('OpenQA::Schema::Result::JobModules');
        $jobs->find($running_job_id)->modules->create({name => 'foo', script => 'bar', category => 'testsuite'});
        $mock->redefine(results => sub ($self, %options) { die 'foo4' });
        $expected_breakage = '';
        $expected_warning = qr/Unable to carry-over bugrefs of job.*: foo4/;
        subtest 'failure when reading job module results does not prevent anything else' => $test_registration;
    };
};


subtest 'server-side limit has precedence over user-specified limit' => sub {
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limits->{generic_max_limit} = 5;
    $limits->{generic_default_limit} = 2;

    # create more test-workers
    my $id = 4;
    for (1 .. 4) {
        $registration_params{instance} = $id;
        $t->post_ok('/api/v1/workers', form => \%registration_params)->status_is(200, 'register new worker')
          ->json_is('/id' => $id, "new worker id is $id");
        always_explain $t->tx->res->json unless $t->success;
        $id++;
    }

    $t->get_ok('/api/v1/workers?limit=10', 'query with exceeding user-specified limit for workers')->status_is(200);
    my $workers = $t->tx->res->json->{workers};
    is ref $workers, 'ARRAY', 'data returned (1)' and is scalar @$workers, 5, 'maximum limit for workers is effective';

    $t->get_ok('/api/v1/workers?limit=3', 'query with exceeding user-specified limit for workers')->status_is(200);
    $workers = $t->tx->res->json->{workers};
    is ref $workers, 'ARRAY', 'data returned (2)' and is scalar @$workers, 3, 'user limit for workers is effective';

    $t->get_ok('/api/v1/workers', 'query with (low) default limit for workers')->status_is(200);
    $workers = $t->tx->res->json->{workers};
    is ref $workers, 'ARRAY', 'data returned (3)' and is scalar @$workers, 2, 'default limit for workers is effective';
};

subtest 'server-side limit with pagination' => sub {
    subtest 'input validation' => sub {
        $t->get_ok('/api/v1/workers?limit=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (limit invalid)'});
        $t->get_ok('/api/v1/workers?offset=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (offset invalid)'});
    };

    subtest 'navigation with limit' => sub {
        my $links;

        subtest 'first page' => sub {
            $t->get_ok('/api/v1/workers?limit=3')->status_is(200)->json_has('/workers/0')->json_has('/workers/2')
              ->json_hasnt('/workers/3');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };

        subtest 'second page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_has('/workers/0')->json_has('/workers/2')
              ->json_hasnt('/workers/3');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'third page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_has('/workers/0')->json_hasnt('/workers/1');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok !$links->{next}, 'no next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'second page (prev link)' => sub {
            $t->get_ok($links->{prev}{link})->status_is(200)->status_is(200)->json_has('/workers/0')
              ->json_has('/workers/2')->json_hasnt('/workers/3');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'first page (first link)' => sub {
            $t->get_ok($links->{first}{link})->status_is(200)->status_is(200)->json_has('/workers/0')
              ->json_has('/workers/2')->json_hasnt('/workers/3');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };
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
            name => 'offline_test:5'
        },
        'Delete worker was logged correctly.'
    );

    $t->delete_ok('/api/v1/workers/99')->status_is(404, 'worker not found');
    $t->delete_ok('/api/v1/workers/1')->status_is(400, 'deleting online worker prevented');
};

done_testing();
