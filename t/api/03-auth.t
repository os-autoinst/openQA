# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::URL;
use Mojo::Util qw(encode hmac_sha1_sum);
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::IPC;
use OpenQA::WebSockets;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# monkey-patch custom helper websocket_nok - copied from websocked_ok and altered
sub Test::Mojo::websocket_nok {
    my ($self, $url) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $tx = $self->ua->build_websocket_tx(@_);

    # Establish WebSocket connection
    @$self{qw(finished messages)} = (undef, []);
    $self->ua->start(
        $tx => sub {
            my ($ua, $tx) = @_;
            $self->{finished} = [] unless $self->tx($tx)->tx->is_websocket;
            $tx->on(finish => sub { shift; $self->{finished} = [@_] });
            $tx->on(binary => sub { push @{$self->{messages}}, [binary => pop] });
            $tx->on(text   => sub { push @{$self->{messages}}, [text   => pop] });
            Mojo::IOLoop->stop;
        });
    Mojo::IOLoop->start;

    my $desc = encode 'UTF-8', "WebSocket handshake with $url should fail";
    return $self->_test('ok', !$self->tx->is_websocket, $desc);
}

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws = OpenQA::WebSockets->new;

my $ret;

subtest 'access limiting for non authenticated users' => sub() {
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(403);
    like(warning { $t->delete_ok('/api/v1/assets/1')->status_is(403) }, qr/missing apisecret/);
};

subtest 'access limiting for authenticated users but not operators nor admins' => sub() {
    $t->ua->apikey('LANCELOTKEY01');
    $t->ua->apisecret('MANYPEOPLEKNOW');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(403);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
};

subtest 'access limiting for authenticated operators but not admins' => sub() {
    $t->ua->apikey('PERCIVALKEY01');
    $t->ua->apisecret('PERCIVALSECRET01');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(200);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
};

subtest 'access granted for admins' => sub() {
    $t->ua->apikey('ARTHURKEY01');
    $t->ua->apisecret('EXCALIBUR');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(200);
    $t->delete_ok('/api/v1/assets/1')->status_is(200);
};

subtest 'wrong api key - expired' => sub() {
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('WHOCARESAFTERALL');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $ret = $t->get_ok('/api/v1/products')->status_is(403);
    is($ret->tx->res->json->{error}, 'api key expired', 'key expired error');
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($ret->tx->res->json->{error}, 'api key expired', 'key expired error');
};

subtest 'wrong api key - not maching key + secret' => sub() {
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('INVALIDSECRET');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $ret = $t->get_ok('/api/v1/products')->status_is(403);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
};

subtest 'wrong api key - replay attack' => sub() {
    $t->ua->apikey('ARTHURKEY01');
    $t->ua->apisecret('EXCALIBUR');
    $t->ua->unsubscribe('start');
    $t->ua->on(
        start => sub {
            my ($self, $tx) = @_;

            my $timestamp = 0;
            my %headers   = (
                Accept            => 'application/json',
                'X-API-Key'       => $self->apikey,
                'X-API-Microtime' => $timestamp,
                'X-API-Hash'      => hmac_sha1_sum($self->_path_query($tx) . $timestamp, $self->apisecret),
            );

            while (my ($k, $v) = each %headers) {
                $tx->req->headers->header($k, $v);
            }
        });
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $ret = $t->get_ok('/api/v1/products')->status_is(403);
    is($ret->tx->res->json->{error}, 'timestamp mismatch', 'timestamp mismatch error');
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($ret->tx->res->json->{error}, 'timestamp mismatch', 'timestamp mismatch error');
};


SKIP: {
    skip "FIXME: how to test Mojo::Lite using Mojo::Test?", 1;
    # Public access to read workers
    $ret = $t->get_ok('/api/v1/workers')->status_is(200);
    $ret = $t->get_ok('/api/v1/workers/1')->status_is(200);
    # But access without API key is denied for websocket connection
    $ret = $t->websocket_nok('/api/v1/workers/1/ws');

    # Valid key with no expiration date works
    $t->ua->apikey('PERCIVALKEY02');
    $t->ua->apisecret('PERCIVALSECRET02');
    $ret = $t->websocket_ok('/api/v1/workers/1/ws')->finish_ok;

    # But only with the right secret
    $t->ua->apisecret('PERCIVALNOSECRET');
    $ret = $t->websocket_nok('/api/v1/workers/1/ws');

    # Keys that are still valid also work
    $t->ua->apikey('PERCIVALKEY01');
    $t->ua->apisecret('PERCIVALSECRET01');
    $ret = $t->websocket_ok('/api/v1/workers/1/ws')->finish_ok;

    # But expired ones don't
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('WHOCARESAFTERALL');
    $ret = $t->websocket_nok('/api/v1/workers/1/ws');

    # Of course, non-existent keys fail
    $t->ua->apikey('INVENTEDKEY01');
    $ret = $t->websocket_nok('/api/v1/workers/1/ws');

    # Valid keys are rejected if the associated user is not operator
    $t->ua->apikey('LANCELOTKEY01');
    $t->ua->apisecret('MANYPEOPLEKNOW');
    $ret = $t->websocket_nok('/api/v1/workers/1/ws');
}

done_testing();
