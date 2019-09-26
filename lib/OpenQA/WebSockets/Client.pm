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
use Carp 'croak';
use OpenQA::Client;
use OpenQA::Utils 'service_port';

has client => sub { OpenQA::Client->new(api => 'localhost') };
has port   => sub { service_port('websocket') };

sub is_worker_connected {
    my ($self, $worker_id) = @_;
    my $res = $self->client->get($self->_api("is_worker_connected/$worker_id"))->result;
    croak "Expected 2xx status from WebSocket server but received @{[$res->code]}" unless $res->is_success;
    return $res->json->{connected};
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

sub _api {
    my ($self, $method) = @_;
    my $port = $self->port;
    return "http://127.0.0.1:$port/api/$method";
}

1;
