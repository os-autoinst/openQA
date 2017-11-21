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
use OpenQA::WebSockets::Server;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Utils 'redirect_output';

OpenQA::WebSockets::Server->new();

subtest "WebSocket Server _workers_checker" => sub {
    use Mojo::Util 'monkey_patch';
    monkey_patch "OpenQA::Schema", connect_db => sub { FooBarTransaction->new };
    my $buffer;
    {
        open my $handle, '>', \$buffer;
        local *STDOUT = $handle;
        OpenQA::WebSockets::Server::_workers_checker;
    };
    like $buffer, qr/Failed dead job detection/;
};

subtest "WebSocket Server _get_stale_worker_jobs" => sub {
    use Mojo::Util 'monkey_patch';
    monkey_patch "OpenQA::WebSockets::Server", app => sub { FooBarTransaction->new };
    FooBarWorker->new->OpenQA::WebSockets::Server::ws_create();
    my $buffer;
    {
        open my $handle, '>', \$buffer;
        local *STDOUT = $handle;
        OpenQA::WebSockets::Server::_get_stale_worker_jobs(-9999999999);
    };
    like $buffer, qr/Worker Boooo not seen since 0 seconds/;
};

subtest "WebSocket Server _message()" => sub {
    use Mojo::Util 'monkey_patch';
    monkey_patch "OpenQA::WebSockets::Server", _get_worker => sub { FooBarWorker->new };
    my $fake_tx = FooBarTransaction->new;
    my $buf;
    redirect_output(\$buf);

    $fake_tx->OpenQA::WebSockets::Server::_message("");

    is @{$fake_tx->{out}}[0], "1003,Received unexpected data from worker, forcing close",
      "WS Server returns 1003 when message is not a hash";

    $fake_tx->OpenQA::WebSockets::Server::_message({type => "status", jobid => 1, data => "mydata"});
    is @{$fake_tx->{w}->{status}}[0], "mydata", "status got updated";

    $buf = undef;

    $fake_tx->OpenQA::WebSockets::Server::_message({type => "FOOBAR"});
    like $buf, qr/Received unknown message type "FOOBAR" from worker/, "log_error on unknown message";

    monkey_patch "Mojo::Transaction::Websocket", send => sub { undef };
    $fake_tx->OpenQA::WebSockets::Server::_message({type => 'worker_status'});
    like $buf, qr/Could not be able to send population number to worker/ or diag explain $buf;

    monkey_patch "OpenQA::WebAPI", schema => sub { undef };
    $fake_tx->OpenQA::WebSockets::Server::_message({type => 'worker_status'});
    like $buf, qr/Failed updating worker seen status/ or diag explain $buf;

    no warnings 'redefine';
    *FooBarWorker::get_websocket_api_version = sub { };
    $fake_tx->OpenQA::WebSockets::Server::_message({type => 'worker_status'});
    like $buf, qr/Received a message from an incompatible worker/ or diag explain $buf;
    is @{$fake_tx->{out}}[1],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";

    $buf = undef;
    *FooBarWorker::get_websocket_api_version = sub { 0 };
    $fake_tx->OpenQA::WebSockets::Server::_message({type => 'property_change'});
    like $buf, qr/Received a message from an incompatible worker/ or diag explain $buf;
    is @{$fake_tx->{out}}[2],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";

    $buf = undef;
    *FooBarWorker::get_websocket_api_version = sub { WEBSOCKET_API_VERSION + 1 };
    $fake_tx->OpenQA::WebSockets::Server::_message({type => 'accepted'});
    like $buf, qr/Received a message from an incompatible worker/ or diag explain $buf;
    is @{$fake_tx->{out}}[3],
      "1008,Connection terminated from WebSocket server - incompatible communication protocol version";

};

done_testing();

sub _store { push(@{shift->{+shift()}}, join(",", @_)); }

package FooBarTransaction;

sub new { bless({w => FooBarWorker->new()->set}, shift) }
sub tx  { shift }
sub app { shift }
sub log { shift }
sub schema          { shift }
sub resultset       { shift }
sub find            { shift->{w} }
sub warn            { return $_[1] }
sub finish          { main::_store(shift, "out", @_) }
sub send            { main::_store(shift, "send", @_) }
sub storage         { shift }
sub datetime_parser { shift }
sub format_datetime { shift }
sub search          { shift }
sub txn_do          { die "BHUAHUAHUAHUA"; }

package FooBarWorker;
my $singleton;
sub new { $singleton ||= bless({}, shift) }
sub set {
    $singleton->{db} = $singleton;
    $singleton->{id} = \&id;
    $singleton;
}
sub id                        { 1 }
sub update_status             { main::_store(shift, "status", @_) }
sub set_property              { main::_store(shift, "property", @_) }
sub param                     { 1 }
sub on                        { shift }
sub inactivity_timeout        { shift }
sub tx                        { shift }
sub max_websocket_size        { shift }
sub name                      { "Boooo" }
sub get_websocket_api_version { OpenQA::Constants::WEBSOCKET_API_VERSION() }

1;
