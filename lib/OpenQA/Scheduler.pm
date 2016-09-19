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

package OpenQA::Scheduler;

use strict;
use warnings;
use base qw/Net::DBus::Object/;
use Net::DBus::Exporter qw/org.opensuse.openqa.Scheduler/;
use Net::DBus::Reactor;
use Data::Dump qw/pp/;

use OpenQA::IPC;
use OpenQA::Scheduler::FakeApp;
use OpenQA::Scheduler::Scheduler qw//;
use OpenQA::Scheduler::Locks qw//;
use OpenQA::Utils qw/log_debug/;
use OpenQA::ServerStartup;

# monkey patching for debugging IPC
sub _is_method_allowed {
    my ($self, $method) = @_;

    my $ret = $self->SUPER::_is_method_allowed($method);
    if ($ret) {
        log_debug "IPC calling $method";
    }
    return $ret;
}

our $fakeapp;
sub run {
    $fakeapp = OpenQA::Scheduler::FakeApp->new;
    OpenQA::ServerStartup::read_config($fakeapp);
    OpenQA::ServerStartup::setup_logging($fakeapp);

    OpenQA::Scheduler->new();
    log_debug("Scheduler started");
    Net::DBus::Reactor->main->run;
}

sub new {
    my ($class) = @_;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc = OpenQA::IPC->ipc;
    return unless $ipc;
    my $service = $ipc->register_service('scheduler');
    my $self = $class->SUPER::new($service, '/Scheduler');
    $self->{ipc} = $ipc;
    bless $self, $class;

    return $self;
}

# Scheduler ABI goes here
## Assets
dbus_method('asset_delete', [['dict', 'string', 'string']], ['uint32']);
sub asset_delete {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_delete(%$args);
    return $rs;
}

dbus_method('asset_get', [['dict', 'string', 'string']], [['dict', 'string', 'string']]);
sub asset_get {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_get(%$args);
    return {} unless $rs && $rs->first;
    my %rs = $rs->first->get_columns;
    return \%rs;
}

dbus_method('asset_list', [['dict', 'string', 'string']], [['array', ['dict', 'string', 'string']]]);
sub asset_list {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_list(%$args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return [$rs->all];
}

dbus_method('asset_register', [['dict', 'string', 'string']], ['uint32']);
sub asset_register {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_register(%$args);
    return 0 unless $rs;
    return $rs->id;
}

dbus_method('job_grab', [['dict', 'string', ['variant']]], [['dict', 'string', ['variant']]]);
sub job_grab {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_grab(%$args);
}

dbus_method('job_restart', [['array', 'uint32']], [['array', 'uint32']]);
sub job_restart {
    my ($self, $args) = @_;
    my @res = OpenQA::Scheduler::Scheduler::job_restart($args);
    return \@res;
}

dbus_method('job_update_status', ['uint32', ['dict', 'string', ['variant']]], ['uint32']);
sub job_update_status {
    my ($self, $jobid, $status) = @_;
}

dbus_method('job_set_waiting', ['uint32'], ['uint32']);
sub job_set_waiting {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_set_waiting($args);
}

dbus_method('job_set_running', ['uint32'], ['uint32']);
sub job_set_running {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_set_running($args);
}

## Worker auth
dbus_method('validate_workerid', ['uint32'], ['bool']);
sub validate_workerid {
    my ($self, $args) = @_;
    my $res = OpenQA::Scheduler::Scheduler::_validate_workerid($args);
    return 1 if ($res);
    return 0;
}

## Lock API
dbus_method('mutex_create', ['string', 'uint32'], ['bool']);
sub mutex_create {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::create(@args);
    return 0 unless $res;
    return 1;
}

dbus_method('mutex_lock', ['string', 'uint32', 'string'], ['int32']);
sub mutex_lock {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::lock(@args);
    return $res;
}

dbus_method('mutex_unlock', ['string', 'uint32'], ['int32']);
sub mutex_unlock {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::unlock(@args);
    return $res;
}

dbus_method('barrier_create', ['string', 'uint32', 'uint32'], ['bool']);
sub barrier_create {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::barrier_create(@args);
    return 0 unless $res;
    return 1;
}

dbus_method('barrier_wait', ['string', 'uint32', 'string'], ['int32']);
sub barrier_wait {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::barrier_wait(@args);
    return $res;
}

dbus_method('barrier_destroy', ['string', 'uint32', 'string'], ['bool']);
sub barrier_destroy {
    my ($self, @args) = @_;
    my $res = OpenQA::Scheduler::Locks::barrier_destroy(@args);
    return 0 unless $res;
    return 1;
}

1;
