# Copyright (C) 2015-2018 SUSE LLC
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

package OpenQA::ResourceAllocator;

use strict;
use warnings;

use base 'Net::DBus::Object';

use Net::DBus::Exporter 'org.opensuse.openqa.ResourceAllocator';
use Net::DBus::Reactor;
use Data::Dump 'pp';
use Scalar::Util 'blessed';
use Try::Tiny;
use OpenQA::IPC;
use OpenQA::Utils qw(log_debug wakeup_scheduler safe_call);
use OpenQA::Resource::Locks ();
use OpenQA::Setup;

my $singleton;

sub quit {
    log_debug("Received abort signal");
    exit 0;
}

sub new {
    my ($class) = @_;
    return $singleton if $singleton;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc = OpenQA::IPC->ipc;
    return unless $ipc;
    my $service = $ipc->register_service('resourceallocator');
    my $self    = $class->SUPER::new($service, '/ResourceAllocator');
    $self->{ipc} = $ipc;
    bless $self, $class;
    $singleton = $self;
    # hook DBus to Mojo reactor
    $singleton->{reactor} = Net::DBus::Reactor->main;
    $singleton->{schema}  = OpenQA::Schema::connect_db();
    $ipc->manage_events(Mojo::IOLoop->singleton->reactor, $singleton);
    return $singleton;
}

sub run {
    my $self = shift;

    # Catch normal signals
    local $SIG{HUP} = local $SIG{INT} = local $SIG{PIPE} = local $SIG{TERM} = sub {
        quit();
    };

    my $setup = OpenQA::Setup->new(log_name => 'resource-allocator');
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);
    log_debug("Resource allocator started");
    $self->{reactor}->run()
      if exists $self->{reactor} && blessed($self->{reactor}) && $self->{reactor}->isa("Net::DBus::Reactor");
}

sub schema { shift->{schema} }

# monkey patching for debugging IPC
sub _is_method_allowed {
    my ($self, $method) = @_;

    my $ret = $self->SUPER::_is_method_allowed($method);
    if ($ret) {
        log_debug "IPC calling $method";
    }
    return $ret;
}


## Lock API
dbus_method('mutex_create', ['string', 'uint32'], ['bool']);
sub mutex_create {
    my ($self, @args) = @_;
}

dbus_method('mutex_lock', ['string', 'uint32', 'string'], ['int32']);
sub mutex_lock {
    my ($self, @args) = @_;
}

dbus_method('mutex_unlock', ['string', 'uint32', 'string'], ['int32']);
sub mutex_unlock {
    my ($self, @args) = @_;
}

dbus_method('barrier_create', ['string', 'uint32', 'uint32'], ['bool']);
sub barrier_create {
    my ($self, @args) = @_;
}

dbus_method('barrier_wait', ['string', 'uint32', 'string', 'uint32'], ['int32']);
sub barrier_wait {
    my ($self, @args) = @_;
}

dbus_method('barrier_destroy', ['string', 'uint32', 'string'], ['bool']);
sub barrier_destroy {
    my ($self, @args) = @_;
}

*instance = \&new;

1;
