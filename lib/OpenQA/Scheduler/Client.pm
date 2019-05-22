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

package OpenQA::Scheduler::Client;
use Mojo::Base -base;

use Mojo::Server::Daemon;
use Carp 'croak';
use OpenQA::Client;
use OpenQA::Scheduler;

has client => sub { OpenQA::Client->new(api => 'localhost') };
has port   => 9529;

sub embed_server_for_testing {
    my $self = shift;

    # Change the current OpenQA::Scheduler::Client instance to use an embedded
    # scheduler server for testing (this avoids forking a second process)
    unless ($self->{test_server}) {
        my $server = $self->{test_server} = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
        $server->build_app('OpenQA::Scheduler');
        $server->start;
        $self->port($server->ports->[0]);
    }

    return $self;
}

sub wakeup {
    my ($self, $worker_id) = @_;
    return if $self->{wakeup};
    $self->{wakeup}++;
    $self->client->max_connections(0)->request_timeout(5)->get_p($self->_api('wakeup'))
      ->finally(sub { delete $self->{wakeup} })->wait;
}

sub singleton { state $client ||= __PACKAGE__->new }

sub _api {
    my ($self, $method) = @_;
    my $port = $self->port;
    return "http://127.0.0.1:$port/api/$method";
}

1;
