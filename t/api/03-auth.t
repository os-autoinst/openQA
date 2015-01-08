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
    unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More tests => 13;
use Test::Mojo;
use Mojo::URL;
use Mojo::Util qw(encode);
use OpenQA::Test::Case;
use OpenQA::API::V1::Client;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

# monkey-patch custom helper websocket_nok - copied from websocked_ok and altered
sub Test::Mojo::websocket_nok{
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
        }
    );
    Mojo::IOLoop->start;

    my $desc = encode 'UTF-8', "WebSocket handshake with $url should fail";
    return $self->_test('ok', !$self->tx->is_websocket, $desc);
}

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::API::V1::Client->new()->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret;

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

done_testing();
