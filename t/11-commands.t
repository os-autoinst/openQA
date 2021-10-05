#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Warnings qw(:all :report_warnings);
use Test::Output 'stderr_like';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebSockets::Client;
use Test::MockModule;
use Mojolicious;
use Mojo::Message;


my $mock_client = Test::MockModule->new('OpenQA::WebSockets::Client');
my ($client_called, $last_command);
$mock_client->redefine(
    send_msg => sub {
        my ($self, $workerid, $command, $jobid) = @_;
        $client_called++;
        $last_command = $command;
    });
my $mock_ws = Test::MockModule->new('OpenQA::WebSockets');
my $last_ws_params;
$mock_ws->redefine(
    ws_send => sub {
        $last_ws_params = [@_];
        return Mojo::Message->new;
    });

#issue valid commands for worker 1
my @valid_commands = qw(quit abort cancel obsolete livelog_stop livelog_start developer_session_start);

my $worker = OpenQA::Schema::Result::Workers->new({host => 'localhost', instance => 1});

for my $cmd (@valid_commands) {
    $worker->send_command(command => $cmd, job_id => 0);
    is($last_command, $cmd, "command $cmd received at WS server");
}
is($last_ws_params, undef, 'ws_send not called directly');

# issue invalid commands
stderr_like { $worker->send_command(command => 'foo', job_id => 0) }
qr/\[ERROR\] Trying to issue unknown command "foo" for worker "localhost:"/;
isnt($last_command, 'foo', 'refuse invalid commands');
ok $client_called, 'mocked send_msg method has been called';

subtest 'ws server does not try to query itself' => sub {
    OpenQA::WebSockets::Client::mark_current_process_as_websocket_server;
    $last_command = undef;
    $worker->send_command(command => $valid_commands[0], job_id => 0);
    is($last_command, undef, 'command not sent via client');
    is_deeply($last_ws_params, [$worker->id, $valid_commands[0], 0, undef], 'ws_send called directly')
      or diag explain $last_ws_params;
};

done_testing();
