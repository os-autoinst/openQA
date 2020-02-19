#!/usr/bin/env perl

# Copyright (C) 2017-2020 SUSE LLC
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

use strict;
use warnings;

use 5.018;
use Test::More;
use POSIX;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use OpenQA::Client;
use OpenQA::Jobs::Constants;
use OpenQA::WebSockets;
use OpenQA::WebSockets::Model::Status;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Test::FakeWebSocketTransaction;
use Test::Output;
use Test::MockModule;
use Test::Mojo;
use Mojo::JSON;

my $schema = OpenQA::Test::Database->new->create;
my $t      = Test::Mojo->new('OpenQA::WebSockets');

subtest 'Authentication' => sub {
    my $app = $t->app;

    combined_like(
        sub {
            $t->get_ok('/test')->status_is(404)->content_like(qr/Not found/);
            $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
            local $t->app->config->{no_localhost_auth} = 0;
            $t->get_ok('/')->status_is(403)->json_is({error => 'Not authorized'});
            $t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')
                  ->ioloop(Mojo::IOLoop->singleton))->app($app);
            $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
        },
        qr/auth by user: percival/,
        'auth logged'
    );

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
    $t->tx($t->ua->start($t->ua->build_websocket_tx('/ws/23')))->status_is(400)->content_like(qr/Unknown worker/);
};

my $workers   = $schema->resultset('Workers');
my $jobs      = $schema->resultset('Jobs');
my $worker    = $workers->search({host => 'localhost', instance => 1})->first;
my $worker_id = $worker->id;
OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id} = {
    id => $worker_id,
    db => $worker,
};

subtest 'web socket message handling' => sub {
    subtest 'unexpected message' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('');
                $t->finished_ok(1003, 'connection closed on unexpected message');
            },
            qr/Received unexpected WS message .* from worker 1/s,
            'unexpected message logged'
        );
    };

    subtest 'incompatible version' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{}');
                $t->message_ok('message received');
                $t->json_message_is({type => 'incompatible'});
                $t->finished_ok(1008, 'connection closed when version incompatible');
            },
            qr/Received a message from an incompatible worker 1/s,
            'incompatible version logged'
        );
    };

    # make sure the API version matches in subsequent tests
    $worker->set_property('WEBSOCKET_API_VERSION', WEBSOCKET_API_VERSION);
    $worker->{_websocket_api_version_} = WEBSOCKET_API_VERSION;

    subtest 'unknown type' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"foo"}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Received unknown message type "foo" from worker 1/s,
            'unknown type logged'
        );
    };

    $schema->txn_begin;

    subtest 'accepted' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"accepted","jobid":42}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Worker 1 accepted job 42.*never assigned/s,
            'warning logged when job has never been assigned'
        );

        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"accepted","jobid":42}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Worker 1 accepted job 42\n/s,
            'debug message logged when job matches previous assignment'
        );
        is($jobs->find(42)->state,    SETUP, 'job is in setup state');
        is($workers->find(1)->job_id, 42,    'job is considered the current job of the worker');
    };

    $schema->txn_rollback;
    $schema->txn_begin;

    subtest 'rejected' => sub {
        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        $jobs->create({id => 43, state => DONE,     assigned_worker_id => 1, TEST => 'foo'});
        $workers->find(1)->update({job_id => 42});
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"rejected","job_ids":[42,43],"reason":"foo"}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Worker 1 rejected job\(s\) 42, 43: foo.*Job 42 reset to state scheduled/s,
            'info logged when worker rejects job'
        );
        is($jobs->find(42)->state,    SCHEDULED, 'job is again in scheduled state');
        is($jobs->find(43)->state,    DONE,      'completed job not affected');
        is($workers->find(1)->job_id, undef,     'job not considered the current job of the worker anymore');
    };

    $schema->txn_rollback;
    $schema->txn_begin;

    subtest 'quit' => sub {
        $jobs->create({id => 42, state => ASSIGNED, assigned_worker_id => 1, TEST => 'foo'});
        ok(!$workers->find(1)->dead, 'worker not considered dead in the first place');
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"quit"}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Job 42 reset to state scheduled/s,
            'info logged when worker rejects job'
        );
        is($jobs->find(42)->state, SCHEDULED,
                'job is immediately set back to scheduled if assigned worker goes offline '
              . 'gracefully before starting to work on the job');
        ok($workers->find(1)->dead, 'worker considered immediately dead when it goes offline gracefully');
    };

    $schema->txn_rollback;
    $t->websocket_ok('/ws/1', 'establish ws connection');

    subtest 'worker status' => sub {
        combined_like(
            sub {
                $t->send_ok({json => {type => 'worker_status', status => 'broken', reason => 'test'}});
                $t->message_ok('message received');
                $t->json_message_is({type => 'info', population => $workers->count});
                is($workers->find($worker_id)->error, 'test', 'broken message set');
            },
            qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s,
            'update logged'
        );

        # assume no job is assigned
        combined_like(
            sub {
                $workers->find($worker_id)->update({job_id => undef});
                $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
                $t->message_ok('message received');
                $t->json_message_is({type => 'info', population => $workers->count});
                is($workers->find($worker_id)->error, undef, 'broken status unset');
            },
            qr/Received.*worker_status message.*Updating seen of worker 1 from worker_status/s,
            'update logged'
        );
    };

    combined_like(
        sub {
            $t->finish_ok(1000, 'finished ws connection');
        },
        qr/Worker 1 websocket connection closed - 1000/s,
        'connection closed logged'
    );
};

done_testing();

1;
