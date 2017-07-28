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
use base 'Net::DBus::Object';
use Net::DBus::Exporter 'org.opensuse.openqa.WebSockets';
use Mojo::IOLoop;
use strict;

use OpenQA::IPC;
use OpenQA::WebSockets::Server ();
use OpenQA::Utils 'log_debug';

# monkey patching for debugging IPC
sub _is_method_allowed {
    my ($self, $method) = @_;

    my $ret = $self->SUPER::_is_method_allowed($method);
    if ($ret) {
        log_debug "IPC calling $method";
    }
    return $ret;
}

sub run {
    # config Mojo to get reactor
    my $server = OpenQA::WebSockets::Server->setup;
    # start DBus
    my $self = OpenQA::WebSockets->new;
    $self->{server} = $server;
    # start IOLoop
    $server->run;
}

sub new {
    my ($class) = @_;
    $class = ref $class || $class;
    my $ipc = OpenQA::IPC->ipc(1);
    return unless $ipc;
    my $service = $ipc->register_service('websockets');
    my $self = $class->SUPER::new($service, '/WebSockets');
    $self->{ipc} = $ipc;
    bless $self, $class;
    # hook DBus to Mojo reactor
    $ipc->manage_events(Mojo::IOLoop->singleton->reactor, $self);

    return $self;
}

# WebSockets ABI goes here
dbus_method('ws_is_worker_connected', ['uint32'], ['bool']);
sub ws_is_worker_connected {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::Server::ws_is_worker_connected(@args);
}

dbus_method('ws_send_job', [['dict', 'string', ['variant']]], [['dict', 'string', ['variant']]]);
sub ws_send_job {
    my ($self, $args) = @_;
    return OpenQA::WebSockets::Server::ws_send_job($args);
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

dbus_method('ws_worker_accepted_job', ['uint32'], ['uint32']);
sub ws_worker_accepted_job {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::Server::ws_worker_accepted_job(@args);
}

1;
