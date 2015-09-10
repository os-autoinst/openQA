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

package OpenQA::WebSockets::DBus;
use strict;
use warnings;
use parent qw/Mojolicious::Plugin/;
use Mojo::IOLoop;

use OpenQA::IPC;

sub register {
    my ($self, $reactor) = @_;
    my $dbus = OpenQA::WebSockets::DBus::Object->new($reactor);
    # register Mojo listeners
    my $ipc = $dbus->{ipc};
    $self->{DBUS} = $dbus;
    return unless ($reactor && ref($reactor) =~ /Mojo::Reactor/);
    $reactor->on('worker_connected'    => sub { my ($e, @args) = @_; $ipc->emit_signal('websockets', 'worker_connected',    @args) });
    $reactor->on('worker_disconnected' => sub { my ($e, @args) = @_; $ipc->emit_signal('websockets', 'worker_disconnected', @args) });
    $reactor->on('command_sent'        => sub { my ($e, @args) = @_; $ipc->emit_signal('websockets', 'command_sent',        @args) });
    $reactor->on('command_failed'      => sub { my ($e, @args) = @_; $ipc->emit_signal('websockets', 'command_failed',      @args) });
    return $self;
}

package OpenQA::WebSockets::DBus::Object;
use strict;
use warnings;
use parent qw/Net::DBus::Object/;
use Net::DBus::Exporter qw/org.opensuse.openqa.WebSockets/;

use OpenQA::IPC;
use OpenQA::WebSockets;

sub new {
    my ($class, $reactor) = @_;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc     = OpenQA::IPC->ipc($reactor);
    my $service = $ipc->register_service('websockets');
    my $self    = $class->SUPER::new($service, '/WebSockets');
    $ipc->register_object('websockets', $self);
    $self->{ipc} = $ipc;
    bless $self, $class;
    # hook DBus to Mojo reactor
    $ipc->manage_events($reactor, $self);
    return $self;
}

# WebSockets DBUS API goes here
dbus_method('ws_is_worker_connected', ['uint32'], ['bool']);
sub ws_is_worker_connected {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::ws_is_worker_connected(@args);
}

dbus_method('ws_send', ['uint32', 'string', 'uint32']);
sub ws_send {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::ws_send(@args);
}

dbus_method('ws_send_all', ['string']);
sub ws_send_all {
    my ($self, @args) = @_;
    return OpenQA::WebSockets::ws_send_all(@args);
}

dbus_signal('worker_connected', [['dict', 'string', ['variant']]]);
dbus_signal('worker_disconnected', ['uint32']);
dbus_signal('command_sent',        ['uint32', ['variant']]);
dbus_signal('command_failed',      ['uint32', ['variant']]);
1;
