# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebSockets;
use base qw/Net::DBus::Object/;
use Net::DBus::Exporter qw/org.opensuse.openqa.WebSockets/;
use Mojo::IOLoop;
use strict;

use OpenQA::IPC;
use OpenQA::WebSockets::Server qw//;

sub run {
    # config Mojo to get reactor
    my $server = OpenQA::WebSockets::Server->setup();
    # start DBus
    my $self = OpenQA::WebSockets->new($server->ioloop->reactor);
    $self->{server} = $server;
    # start IOLoop
    $server->run;
}

sub new {
    my ($class, $reactor) = @_;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc = OpenQA::IPC->ipc($reactor);
    return unless $ipc;
    my $service = $ipc->register_service('websockets');
    my $self = $class->SUPER::new($service, '/WebSockets');
    $self->{ipc} = $ipc;
    bless $self, $class;
    # hook DBus to Mojo reactor
    $ipc->manage_events($reactor, $self);
    return $self;
}

# WebSockets ABI goes here
dbus_method('ws_is_worker_connected', ['uint32'], ['bool']);
sub ws_is_worker_connected {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::Server::ws_is_worker_connected(@args);
}

dbus_method('ws_send', ['uint32', 'string', 'uint32']);
sub ws_send {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::Server::ws_send(@args);
}

dbus_method('ws_send_all', ['string']);
sub ws_send_all {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::Server::ws_send_all(@args);
}

dbus_method('ws_notify_workers');
sub ws_notify_workers {
    my ($self) = @_;
    return OpenQA::WebSockets::Server::ws_send_all(('job_available'));
}

1;
