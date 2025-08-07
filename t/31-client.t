# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '6';

use Test::Mojo;
use Test::MockModule;
use Test::MockObject;
use Test::Output;
use Test::Warnings ':report_warnings';
use OpenQA::WebAPI;
use OpenQA::Test::Case;
use OpenQA::Scheduler::Client;
use OpenQA::WebSockets::Client;
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

done_testing();
