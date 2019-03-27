# Copyright (C) 2014-2019 SUSE LLC
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

package OpenQA::WebSockets::Client;
use Mojo::Base -base;

use Mojo::Server::Daemon;
use OpenQA::Client;
use OpenQA::WebSockets::Server;

has client => sub { OpenQA::Client->new(api => 'localhost') };
has port   => 9527;

sub embed_server_for_testing {
    my $self = shift;

    # Change the current OpenQA::WebSockets::Client instance to use an embedded
    # websocket server for testing (this avoids forking a second process)
    unless ($self->{test_server}) {
        my $server = $self->{test_server} = Mojo::Server::Daemon->new(
            ioloop => $self->client->ioloop,
            listen => ['http://127.0.0.1']);
        $server->build_app('OpenQA::WebSockets::Server');
        $server->start;
        $self->port($server->ports->[0]);
    }

    return $self;
}

sub is_worker_connected {
    my ($self, $worker_id) = @_;

    my $port = $self->port;
    my $url  = "http://localhost:$port/api/is_worker_connected/$worker_id";
    my $res  = $self->client->get($url)->result;

    return $res->json->{connected};
}

sub singleton { state $client ||= __PACKAGE__->new }

1;
