#!/usr/bin/perl

# Copyright (C) 2017 SUSE LLC
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

use 5.018;
use warnings;
use strict;
use Test::More;
use POSIX;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use OpenQA::Client;
use OpenQA::WebSockets::Server;
use OpenQA::WebSockets::Controller::Worker;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Test::Utils 'redirect_output';
use Test::MockModule;
use Test::Mojo;
use Mojo::JSON;

# Pretend the class was loaded with "require"
$INC{'FooBarWorker.pm'} = 1;

OpenQA::Test::Database->new->create;
my $t = Test::Mojo->new('OpenQA::WebSockets::Server');

subtest 'Authentication' => sub {
    $t->get_ok('/test')->status_is(404);

    $t->get_ok('/')->status_is(403)->json_is({error => 'Not authorized'});
    my $app = $t->app;
    $t->ua(
        OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton)
    )->app($app);
    $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
};

subtest 'API' => sub {
    $t->get_ok('/api/is_worker_connected/1')->status_is(200)->json_is({connected => Mojo::JSON::false});
    local $t->app->status->workers->{1} = {socket => 1};
    $t->get_ok('/api/is_worker_connected/1')->status_is(200)->json_is({connected => Mojo::JSON::true});
};

subtest 'WebSocket Server workers_checker' => sub {
    my $mock_schema = Test::MockModule->new('OpenQA::Schema');
    my $mock_singleton_called;
    $mock_schema->mock(singleton => sub { $mock_singleton_called++; FooBarTransaction->new });
    my $buffer;
    {
        open my $handle, '>', \$buffer;
        local *STDOUT = $handle;
        OpenQA::WebSockets::Server->new->workers_checker;
    };
    like $buffer,              qr/Failed dead job detection/;
    ok $mock_singleton_called, 'mocked singleton method has been called';
};

subtest 'WebSocket Server get_stale_worker_jobs' => sub {
    my $mock_schema = Test::MockModule->new('OpenQA::Schema');
    my $mock_singleton_called;
    $mock_schema->mock(singleton => sub { $mock_singleton_called++; FooBarTransaction->new });
    FooBarTransaction->new->OpenQA::WebSockets::Controller::Worker::ws();
    my $buffer;
    {
        open my $handle, '>', \$buffer;
        local *STDOUT = $handle;
        OpenQA::WebSockets::Server->new->get_stale_worker_jobs(-9999999999);
    };
    like $buffer,              qr/Worker Boooo not seen since \d+ seconds/;
    ok $mock_singleton_called, 'mocked singleton method has been called';
};

subtest 'WebSocket Server _message()' => sub {
    my $mock_controller = Test::MockModule->new('OpenQA::WebSockets::Controller::Worker');
    my $mock_get_worker_called;
    $mock_controller->mock(_get_worker => sub { $mock_get_worker_called++; FooBarWorker->new });
    my $fake_tx = FooBarTransaction->new;
    my $buf;
    redirect_output(\$buf);

    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message("");
    is @{$fake_tx->{out}}[0], "1003,Received unexpected data from worker, forcing close",
      "WS Server returns 1003 when message is not a hash";
    ok $mock_get_worker_called, 'mocked _get_worker method has been called';

    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => "status", jobid => 1, data => "mydata"});
    is @{$fake_tx->{w}->{status}}[0], "mydata", "status got updated";

    $buf = undef;
    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => "FOOBAR"});
    like $buf, qr/Received unknown message type "FOOBAR" from worker/, "log_error on unknown message";

    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => 'worker_status'});
    like($buf, qr/Could not send the population number to worker/, 'worker population unavailable')
      or diag explain $buf;

    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => 'worker_status'});
    like($buf, qr/Failed updating worker seen and error status/, 'seen/error not available')
      or diag explain $buf;

    my $mock_foo = Test::MockModule->new('FooBarWorker');
    my $mock_version_called;
    $mock_foo->mock(websocket_api_version => sub { $mock_version_called++; undef });
    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => 'worker_status'});
    like($buf, qr/Received a message from an incompatible worker/, 'worker incompatible')
      or diag explain $buf;
    is @{$fake_tx->{out}}[1],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";
    ok $mock_version_called, 'mocked websocket_api_version method has been called';

    $buf                 = undef;
    $mock_version_called = undef;
    $mock_foo->mock(websocket_api_version => sub { $mock_version_called++; 0 });
    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => 'property_change'});
    like $buf, qr/Received a message from an incompatible worker/ or diag explain $buf;
    is @{$fake_tx->{out}}[2],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";
    ok $mock_version_called, 'mocked websocket_api_version method has been called';

    $buf                 = undef;
    $mock_version_called = undef;
    $mock_foo->mock(websocket_api_version => sub { $mock_version_called++; WEBSOCKET_API_VERSION + 1 });
    $fake_tx->OpenQA::WebSockets::Controller::Worker::_message({type => 'accepted'});
    like $buf, qr/Received a message from an incompatible worker/ or diag explain $buf;
    is @{$fake_tx->{out}}[3],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";
    ok $mock_version_called, 'mocked websocket_api_version method has been called';

};

done_testing();

sub _store { push(@{shift->{+shift()}}, join(",", @_)); }

package FooBarTransaction;

sub new { bless({w => FooBarWorker->new()->set}, shift) }
sub tx  { shift }
sub app { shift }
sub log { shift }
sub schema             { shift }
sub status             { OpenQA::WebSockets::Model::Status->singleton }
sub resultset          { shift }
sub find               { shift->{w} }
sub on                 { shift }
sub param              { 1 }
sub warn               { return $_[1] }
sub finish             { main::_store(shift, "out", @_) }
sub send               { main::_store(shift, "send", @_) }
sub storage            { shift }
sub datetime_parser    { shift }
sub inactivity_timeout { shift }
sub max_websocket_size { shift }
sub format_datetime    { shift }
sub search             { shift }
sub txn_do             { die "BHUAHUAHUAHUA"; }

package FooBarWorker;
my $singleton;
sub new { $singleton ||= bless({}, shift) }
sub set {
    $singleton->{db} = $singleton;
    $singleton->{id} = \&id;
    $singleton;
}
sub id                    { 1 }
sub update_status         { main::_store(shift, "status", @_) }
sub set_property          { main::_store(shift, "property", @_) }
sub tx                    { shift }
sub name                  { "Boooo" }
sub websocket_api_version { OpenQA::Constants::WEBSOCKET_API_VERSION() }

1;
