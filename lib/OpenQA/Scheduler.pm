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

use base 'Net::DBus::Object';

use Net::DBus::Exporter 'org.opensuse.openqa.Scheduler';
use Net::DBus::Reactor;
use OpenQA::IPC;
use OpenQA::Setup;
use OpenQA::Utils 'log_debug';

# How many jobs to allocate in one tick. Defaults to 80 ( set it to 0 for as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 80;

# Scheduler default clock. Defaults to 20 s
# Optimization rule of thumb is:
# if we see a enough big number of messages while in debug mode stating "Congestion control"
# we might consider touching this value, as we may have a very large cluster to deal with.
# To have a good metric: you might raise it just above as the maximum observed time
# that the scheduler took to perform the operations
use constant SCHEDULE_TICK_MS => $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} // 20000;

# monkey patching for debugging IPC
sub _is_method_allowed {
    my ($self, $method) = @_;

    my $ret = $self->SUPER::_is_method_allowed($method);
    if ($ret) {
        log_debug "IPC calling $method";
    }
    return $ret;
}

our $setup;
sub run {

    # Catch normal signals
    local $SIG{HUP} = local $SIG{INT} = local $SIG{PIPE} = local $SIG{TERM} = sub {
        OpenQA::Scheduler::Scheduler::quit();
    };

    $setup = OpenQA::Setup->new(log_name => 'scheduler');
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);

    OpenQA::Scheduler->new();
    log_debug("Scheduler started");
    log_debug("\t Scheduler default interval(ms) : " . SCHEDULE_TICK_MS);
    log_debug("\t Max job allocation: " . MAX_JOB_ALLOCATION);

    my $reactor = Net::DBus::Reactor->main;
    OpenQA::Scheduler::Scheduler::reactor($reactor);
    $reactor->{timer}->{schedule_jobs} = $reactor->add_timeout(
        SCHEDULE_TICK_MS,
        Net::DBus::Callback->new(
            method => \&OpenQA::Scheduler::Scheduler::schedule
        ));
    # initial schedule
    OpenQA::Scheduler::Scheduler::schedule();

    $reactor->run;
}

sub new {
    my ($class) = @_;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc = OpenQA::IPC->ipc;
    return unless $ipc;
    my $service = $ipc->register_service('scheduler');
    my $self    = $class->SUPER::new($service, '/Scheduler');
    $self->{ipc} = $ipc;
    bless $self, $class;

    return $self;
}

# Scheduler ABI goes here

dbus_method('wakeup_scheduler');
sub wakeup_scheduler {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::wakeup_scheduler();
}


1;
