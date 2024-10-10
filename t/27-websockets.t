#!/usr/bin/env perl

# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use 5.018;
use POSIX;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';

BEGIN { $ENV{OPENQA_LOG_WORKER_STATUS_MESSAGES} = 1 }

use OpenQA::Jobs::Constants;
use OpenQA::WebSockets;
use OpenQA::WebSockets::Model::Status;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Client 'client';
require OpenQA::Test::Database;
use OpenQA::Test::FakeWebSocketTransaction;
use Test::Output;
use Test::MockModule;
use Test::Mojo;
use Mojo::JSON;

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebSockets');
my $t2 = client(Test::Mojo->new('OpenQA::WebSockets'));
my $misc_limits = $t->app->config->{misc_limits} //= {};
my $workers = $schema->resultset('Workers');
my $jobs = $schema->resultset('Jobs');
my $worker = $workers->find({host => 'localhost', instance => 1});
my $worker_id = $worker->id;
my $status = OpenQA::WebSockets::Model::Status->singleton->workers;

subtest 'Authentication' => sub {
    my $app = $t->app;

    combined_like {
        $t->get_ok('/test')->status_is(404)->content_like(qr/Not found/);
        $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
        local $t->app->config->{no_localhost_auth} = 0;
        $t->get_ok('/')->status_is(403)->json_is({error => 'Not authorized'});
        client($t);
        $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
    }
    qr/auth by user: percival/, 'auth logged';

    my $c = $t->app->build_controller;
    $c->tx->remote_address('127.0.0.1');
    ok $c->is_local_request, 'is localhost';
    $c->tx->remote_address('::1');
    ok $c->is_local_request, 'is localhost';
    $c->tx->remote_address('192.168.2.1');
    ok !$c->is_local_request, 'not localhost';
};

subtest 'Exception' => sub {
    $t->app->plugins->once(before_dispatch => sub { die 'Just a test exception!' });
    $t->get_ok('/whatever')->status_is(500)->content_like(qr/Just a test exception!/);
    $t->get_ok('/whatever')->status_is(404);
};

subtest 'API' => sub {
    $t->tx($t->ua->start($t->ua->build_websocket_tx('/ws/23')));
    $t->status_is(400, 'no ws connection for unregistered worker');
    $t->content_like(qr/Unknown worker/, 'error about unknown worker');

    $worker->update({job_id => undef});
    $misc_limits->{max_online_workers} = 0;
    $misc_limits->{worker_limit_retry_delay} = 42;
    $t->tx($t->ua->start($t->ua->build_websocket_tx('/ws/1')));
    $t->status_is(429, 'no ws connection for limited worker')->content_like(qr/Limit.*exceeded/, 'error about limit');
    $worker->discard_changes;
    like $worker->error, qr/^limited at .*/, 'worker flagged as limited via error field excluding it from assignments';
};

$misc_limits->{max_online_workers} = undef;
$status->{$worker_id} = {id => $worker_id, db => $worker};

subtest 'web socket message handling' => sub {
    subtest 'unexpected message' => sub {
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('');
            $t->finished_ok(1003, 'connection closed on unexpected message');
        }
        qr/Received unexpected WS message .* from worker 1/s, 'unexpected message logged';
    };

    subtest 'incompatible version' => sub {
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{}');
            $t->message_ok('message received');
            $t->json_message_is({type => 'incompatible'});
            $t->finished_ok(1008, 'connection closed when version incompatible');
        }
        qr/Received a message from an incompatible worker 1/s, 'incompatible version logged';
    };

    # make sure the API version matches in subsequent tests
    $worker->set_property('WEBSOCKET_API_VERSION', WEBSOCKET_API_VERSION);
    $worker->{_websocket_api_version} = WEBSOCKET_API_VERSION;

    subtest 'unknown type' => sub {
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{"type":"foo"}');
            $t->finish_ok(1000, 'finished ws connection');
        }
        qr/Received unknown message type "foo" from worker 1/s, 'unknown type logged';
    };

    $schema->txn_begin;

    subtest 'accepted' => sub {
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{"type":"accepted","jobid":42}');
            $t->finish_ok(1000, 'finished ws connection');
        }
        qr/Worker 1 accepted job 42.*never assigned/s, 'warning logged when job has never been assigned';

        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{"type":"accepted","jobid":42}');
            $t->finish_ok(1000, 'finished ws connection');
        }
        qr/Worker 1 accepted job 42\n/s, 'debug message logged when job matches previous assignment';
        is($jobs->find(42)->state, SETUP, 'job is in setup state');
        is($workers->find(1)->job_id, 42, 'job is considered the current job of the worker');
    };

    subtest 'multiple ws connections handled gracefully' => sub {
        combined_like {
            $t->websocket_ok('/ws/1', 'establish first ws connection');
            $t2->websocket_ok('/ws/1', 'establish second ws connection');
            $t->finished_ok(1008, 'first ws connection finished due to second connection');
            $t2->finish_ok(1000, 'finished second ws connection');
        }
        qr/only one connection per worker allowed/s, '2nd connection attempt logged';
    };

    $schema->txn_rollback;
    $schema->txn_begin;

    subtest 'rejected' => sub {
        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        $jobs->create({id => 43, state => DONE, assigned_worker_id => 1, TEST => 'foo'});
        $workers->find(1)->update({job_id => 42});
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{"type":"rejected","job_ids":[42,43],"reason":"foo"}');
            $t->finish_ok(1000, 'finished ws connection');
        }
        qr/Worker 1 rejected job\(s\) 42, 43: foo.*Job 42 reset to state scheduled/s,
          'info logged when worker rejects job';
        is($jobs->find(42)->state, SCHEDULED, 'job is again in scheduled state');
        is($jobs->find(43)->state, DONE, 'completed job not affected');
        is($workers->find(1)->job_id, undef, 'job not considered the current job of the worker anymore');
    };

    $schema->txn_rollback;
    $schema->txn_begin;

    subtest 'quit' => sub {
        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        my $worker = $workers->find(1);
        $worker->seen;
        combined_like {
            $t->websocket_ok('/ws/1', 'establish ws connection');
            $t->send_ok('{"type":"quit"}');
            $t->finish_ok(1000, 'finished ws connection');
        }
        qr/Job 42 reset to state scheduled/s, 'info logged when worker rejects job';
        is($jobs->find(42)->state, SCHEDULED,
                'job is immediately set back to scheduled if assigned worker goes offline '
              . 'gracefully before starting to work on the job');
        $worker->discard_changes;
        ok($worker->dead, 'worker considered immediately dead when it goes offline gracefully');
        like($worker->error, qr/graceful disconnect at .*/, 'graceful disconnect logged');
    };

    $schema->txn_rollback;
    $t->websocket_ok('/ws/1', 'establish ws connection');

    subtest 'worker status: updates sent too frequently (less than minimal interval)' => sub {
        my $expected_message = qr/Received worker 1 status too close to the last update/s;

        combined_unlike {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}})->message_ok('message received');
        }
        $expected_message, 'status update not yet too frequent';

        combined_unlike {
            $t->finish_ok->websocket_ok('/ws/1', 're-establish ws connection')
              ->send_ok({json => {type => 'worker_status', status => 'idle'}})->message_ok('message received');
        }
        $expected_message, 'status update not yet too frequent due to reconnect';

        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}})->message_ok('message received');
        }
        $expected_message, 'status update too frequent';

        combined_unlike {
            $t->finish_ok->websocket_ok('/ws/1', 're-establish ws connection')
              ->send_ok({json => {type => 'worker_status', status => 'idle'}})->message_ok('message received');
        }
        $expected_message, 'status update not yet too frequent due to another reconnect';

        combined_unlike {
            $t->send_ok({json => {type => 'worker_status', status => 'working'}})->message_ok('message received');
        }
        $expected_message, 'status update not too frequent for status "working"';
    };

    subtest 'worker status: broken' => sub {
        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'broken', reason => 'test'}});
            $t->message_ok('message received');
            $t->json_message_is({type => 'info', seen => 1});
        }
        qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s, 'update logged';
        is($workers->find($worker_id)->error, 'test', 'broken message set');
    };

    subtest 'worker status: idle but worker supposed to run a job' => sub {
        # assume the worker sends a status update claiming it is free when that's actually the case
        $workers->find($worker_id)->update({job_id => undef});
        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
            $t->message_ok('message received');
        }
        qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s, 'update logged';
        ok(!$status->{$worker_id}->{idle_despite_job_assignment},
            'the idle message has not been remarked because there is no job assignment');

        # assign now a job to the worker
        my $assigned_job_id = 99963;
        my $assigned_job = $jobs->find($assigned_job_id);
        $workers->find($worker_id)->update({job_id => $assigned_job_id});
        $assigned_job->update({state => ASSIGNED});

        # assume the worker sends another status update claiming it is free - the worker should have a 2nd attempt
        # to process the assignment before it is removed
        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
            $t->message_ok('message received');
        }
        qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s, 'update logged';
        is($workers->find($worker_id)->error, undef, 'broken status unset');
        is($status->{$worker_id}->{idle_despite_job_assignment}, 1, 'the first idle message has been remarked');
        is($workers->find($worker_id)->job_id, $assigned_job_id, 'but job assignment has not been removed yet');

        # assume the worker sends another status update claiming it is free - the worker failed its 2nd attempt
        # to process the assignment so it is supposed to be removed
        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
            $t->message_ok('message received');
        }
        qr/Rescheduling jobs assigned to worker $worker_id/s, 'rescheduling logged';
        is($workers->find($worker_id)->job_id, undef, 'job assignment removed on 2nd idle status');
        is($jobs->find($assigned_job_id)->state, SCHEDULED, 'job set back to scheduled');
    };

    subtest 'worker status: idle and worker supposed to be idle' => sub {
        $workers->find($worker_id)->update({error => 'assume worker is broken'});
        combined_like {
            $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
            $t->message_ok('message received');
        }
        qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s, 'update logged';
        is($workers->find($worker_id)->error, undef, 'broken status unset');
    };

    combined_like {
        $t->finish_ok(1000, 'finished ws connection');
    }
    qr/Worker 1 websocket connection closed - 1000/s, 'connection closed logged';
};

done_testing();

1;
