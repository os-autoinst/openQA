# Copyright (C) 2014-2021 SUSE LLC
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
use Mojo::Base -base, -signatures;

use Mojo::Server::Daemon;
use Carp 'croak';
use OpenQA::Client;
use OpenQA::Utils qw(address_ipv4 service_port);

has host   => sub { $ENV{OPENQA_WEB_SOCKETS_HOST} };
has client => sub { OpenQA::Client->new(api => shift->host // 'localhost') };
has port   => sub { service_port('websocket') };

my $IS_WS_SERVER_ITSELF;
sub mark_current_process_as_websocket_server { $IS_WS_SERVER_ITSELF = 1; }
sub is_current_process_the_websocket_server  { return $IS_WS_SERVER_ITSELF; }

sub new {
    my $class = shift;
    die 'creating an OpenQA::WebSockets::Client from the Websocket server itself is forbidden'
      if is_current_process_the_websocket_server;
    $class->SUPER::new(@_);
}

sub send_job {
    my ($self, $job) = @_;
    my $res = $self->client->post($self->_api('send_job'), json => $job)->result;
    croak "Expected 2xx status from WebSocket server but received @{[$res->code]}" unless $res->is_success;
    return $res->json->{result};
}

sub send_jobs {
    my ($self, $job_info) = @_;
    my $res = $self->client->post($self->_api('send_jobs'), json => $job_info)->result;
    croak "Expected 2xx status from WebSocket server but received @{[$res->code]}" unless $res->is_success;
    return $res->json->{result};
}

sub send_msg {
    my ($self, $worker_id, $msg, $job_id, $retry) = @_;
    my $data = {worker_id => $worker_id, msg => $msg, job_id => $job_id, retry => $retry};
    my $res  = $self->client->post($self->_api('send_msg'), json => $data)->result;
    croak "Expected 2xx status from WebSocket server but received @{[$res->code]}" unless $res->is_success;
    return $res->json->{result};
}

sub singleton { state $client ||= __PACKAGE__->new }

sub _api ($self, $method) {
    my ($host, $port) = ($self->host // '127.0.0.1', $self->port);
    return "http://$host:$port/api/$method";
}

1;
