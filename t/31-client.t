# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '6';

use Test::Mojo;
use Test::MockModule;
use Test::MockObject;
use Test::Mock::Time;
use Test::Output;
use Test::Warnings ':report_warnings';
use OpenQA::Client;
use OpenQA::WebAPI;
use OpenQA::Test::Case;
use OpenQA::Test::FakeWorker;
use OpenQA::Scheduler::Client;
use OpenQA::WebSockets::Client;
use OpenQA::Worker::Settings;
use OpenQA::Worker::WebUIConnection;
use Mojo::File qw(tempdir);

subtest 'hostnames configurable' => sub {
    my $config_dir = tempdir;
    $config_dir->child('client.conf')->spew("[foo]\nkey = fookey\nsome = config\n[bar]\nkey = barkey");
    ($ENV{OPENQA_CONFIG}, $ENV{OPENQA_SCHEDULER_HOST}, $ENV{OPENQA_WEB_SOCKETS_HOST}) = ($config_dir, qw(foo bar));
    my $scheduler_client = OpenQA::Scheduler::Client->new;
    is $scheduler_client->host, 'foo', 'scheduler hostname configurable';
    is $scheduler_client->client->apikey, 'fookey', 'scheduler hostname passed to client';
    my $ws_client = OpenQA::WebSockets::Client->new;
    is $ws_client->host, 'bar', 'websockets hostname configurable';
    is $ws_client->client->apikey, 'barkey', 'websockets hostname passed to client';
};

subtest 'client instantiation prevented from the daemons itself' => sub {
    OpenQA::WebSockets::Client::mark_current_process_as_websocket_server;
    throws_ok(
        sub {
            OpenQA::WebSockets::Client->singleton;
        },
        qr/is forbidden/,
        'can not create ws server client from ws server itself'
    );

    OpenQA::Scheduler::Client::mark_current_process_as_scheduler;
    throws_ok(
        sub {
            OpenQA::Scheduler::Client->singleton;
        },
        qr/is forbidden/,
        'can not create scheduler client from scheduler itself'
    );
};

subtest 'evaluate_retry_after with integer value' => sub {
    my $ua = OpenQA::Client->new;
    my $tx = $ua->build_tx(GET => 'http://localhost');
    $tx->res->code(429);
    $tx->res->headers->header('Retry-After' => '15');
    is $ua->evaluate_retry_after($tx), 15, 'correct delay parsed for integer';
};

subtest 'evaluate_retry_after with HTTP-date' => sub {
    my $ua = OpenQA::Client->new;
    my $tx = $ua->build_tx(GET => 'http://localhost');
    $tx->res->code(429);

    my $future_date = Mojo::Date->new(time + 30)->to_string;
    $tx->res->headers->header('Retry-After' => $future_date);

    my $delay = $ua->evaluate_retry_after($tx);
    ok $delay >= 29 && $delay <= 30, "correct delay parsed for HTTP-date ($delay)";
};

subtest 'evaluate_retry_after with invalid/empty value' => sub {
    my $ua = OpenQA::Client->new;
    my $tx = $ua->build_tx(GET => 'http://localhost');
    is $ua->evaluate_retry_after($tx), undef, 'undef for no header';

    $tx->res->headers->header('Retry-After' => '');
    is $ua->evaluate_retry_after($tx), undef, 'undef for empty header';

    $tx->res->headers->header('Retry-After' => 'not-a-date-or-int');
    is $ua->evaluate_retry_after($tx), undef, 'undef for invalid value';

    my $time = time;
    $ua->delay($tx, 42);
    is time - $time, 42, 'delay falls back to default if Retry-After header is invalid/empty';
};

subtest 'evaluate_error tests' => sub {
    my $connection = OpenQA::Worker::WebUIConnection->new('http://127.0.0.1:1', {});
    $connection->worker(OpenQA::Test::FakeWorker->new(settings => OpenQA::Worker::Settings->new(1, {})));

    subtest 'evaluate_error with 429 and Retry-After' => sub {
        my $tx = $connection->ua->build_tx(GET => 'http://localhost');
        $tx->res->code(429);
        $tx->res->headers->header('Retry-After' => '45');
        $tx->res->error({message => 'Too Many Requests', code => 429});

        my $remaining_tries = 3;
        my ($msg, $retry_delay) = $connection->evaluate_error($tx, \$remaining_tries);

        is $remaining_tries, 2, 'remaining tries decremented';
        is $retry_delay, 45, 'evaluate_error respects Retry-After header';
    };

    subtest 'evaluate_error behavior on 400 vs 429' => sub {
        my $tx_400 = $connection->ua->build_tx(GET => 'http://localhost');
        $tx_400->res->code(400);
        $tx_400->res->error({message => 'Bad Request', code => 400});
        my $tries_400 = 3;
        $connection->evaluate_error($tx_400, \$tries_400);
        is $tries_400, 0, '400 Bad Request immediately set remaining tries to 0';

        my $tx_429 = $connection->ua->build_tx(GET => 'http://localhost');
        $tx_429->res->code(429);
        $tx_429->res->error({message => 'Too Many Requests', code => 429});
        my $tries_429 = 3;
        $connection->evaluate_error($tx_429, \$tries_429);
        is $tries_429, 2, '429 Too Many Requests does not immediately set remaining tries to 0';
    };
};

done_testing();
