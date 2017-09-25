# Copyright (C) 2015-2016 SUSE LLC
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

use OpenQA::IPC;
use OpenQA::Utils qw(log_debug wakeup_scheduler exists_worker);
use OpenQA::ServerStartup;
use OpenQA::Resource::Jobs  ();
use OpenQA::Resource::Locks ();
use OpenQA::FakeApp;
use sigtrap handler => \&normal_signals_handler, 'normal-signals';

my $singleton;

sub normal_signals_handler {
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
    my $self = $class->SUPER::new($service, '/ResourceAllocator');
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
    my $fakeapp = OpenQA::FakeApp->new(log_name => 'resource-allocator');
    OpenQA::ServerStartup::read_config($fakeapp);
    OpenQA::ServerStartup::setup_logging($fakeapp);
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



## Assets
dbus_method('asset_list', [['dict', 'string', 'string']], [['array', ['dict', 'string', 'string']]]);
sub asset_list {
    my ($self, $args) = @_;
    my $rs = OpenQA::Resource::Jobs::asset_list(%$args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return [$rs->all];
}

dbus_method('job_restart', [['array', 'uint32']], [['array', 'uint32']]);
sub job_restart {
    my ($self, $args) = @_;
    my @res = OpenQA::Resource::Jobs::job_restart($args);
    return \@res;
}

dbus_method('job_update_status', ['uint32', ['dict', 'string', ['variant']]], ['uint32']);
sub job_update_status {
    my ($self, $jobid, $status) = @_;
}

dbus_method('job_set_waiting', ['uint32'], ['uint32']);
sub job_set_waiting {
    my ($self, $args) = @_;
    return OpenQA::Resource::Jobs::job_set_waiting($args);
}

dbus_method('job_set_running', ['uint32'], ['uint32']);
sub job_set_running {
    my ($self, $args) = @_;
    return OpenQA::Resource::Jobs::job_set_running($args);
}

## Worker auth
dbus_method('validate_workerid', ['uint32'], ['bool']);
sub validate_workerid {
    my ($self, $args) = @_;
    my $res = exists_worker($self->schema, $args);
    return 1 if ($res);
    return 0;
}

## Lock API
dbus_method('mutex_create', ['string', 'uint32'], ['bool']);
sub mutex_create {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::create(@args);
    return 0 unless $res;
    return 1;
}

dbus_method('mutex_lock', ['string', 'uint32', 'string'], ['int32']);
sub mutex_lock {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::lock(@args);
    return $res;
}

dbus_method('mutex_unlock', ['string', 'uint32'], ['int32']);
sub mutex_unlock {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::unlock(@args);
    return $res;
}

dbus_method('barrier_create', ['string', 'uint32', 'uint32'], ['bool']);
sub barrier_create {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::barrier_create(@args);
    return 0 unless $res;
    return 1;
}

dbus_method('barrier_wait', ['string', 'uint32', 'string'], ['int32']);
sub barrier_wait {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::barrier_wait(@args);
    return $res;
}

dbus_method('barrier_destroy', ['string', 'uint32', 'string'], ['bool']);
sub barrier_destroy {
    my ($self, @args) = @_;
    my $res = OpenQA::Resource::Locks::barrier_destroy(@args);
    return 0 unless $res;
    return 1;
}

*instance = \&new;

1;
