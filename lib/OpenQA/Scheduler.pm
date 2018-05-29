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
use Data::Dump 'pp';

use OpenQA::IPC;
use OpenQA::Setup;

use OpenQA::Utils 'log_debug';

# How many jobs to allocate in one tick. Defaults to 80 ( set it to 0 for as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 80;

# How many attempts have to be performed to find a job before assuming there is nothing to be scheduled. Defaults to 1
use constant FIND_JOB_ATTEMPTS => $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS} // 1;

# Scheduler default clock. Defaults to 8s
# Optimization rule of thumb is:
# if we see a enough big number of messages while in debug mode stating "Congestion control"
# we might consider touching this value, as we may have a very large cluster to deal with.
# To have a good metric: you might raise it just above as the maximum observed time
# that the scheduler took to perform the operations
# if CONGESTION_CONTROL or BUSY_BACKOFF is enabled, scheduler will change the clock time
# so it's really not needed to touch this value unless you observe a real performance degradation.
use constant SCHEDULE_TICK_MS => $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} // 2000;

# backoff to avoid congestion.
# Enable it with 1, disable with 0. Following options depends on it.
use constant CONGESTION_CONTROL => $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL} // 1;

# Wakes up the scheduler on request
use constant WAKEUP_ON_REQUEST => $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST} // 1;

# Timeslot. Defaults to SCHEDULE_TICK_MS
use constant TIMESLOT => $ENV{OPENQA_SCHEDULER_TIMESLOT} // SCHEDULE_TICK_MS;

# Maximum backoff. Defaults to 60s
use constant MAX_BACKOFF => $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} // 60000;

# Timer reset to avoid starvation caused by CONGESTION_CONTROL/BUSY_BACKOFF. Defaults to 120s
use constant CAPTURE_LOOP_AVOIDANCE => $ENV{OPENQA_SCHEDULER_CAPTURE_LOOP_AVOIDANCE} // 120000;

# set it to 1 if you want to backoff when no jobs can be assigned or we are really busy
# Default is enabled as CONGESTION_CONTROL.
use constant BUSY_BACKOFF => $ENV{OPENQA_SCHEDULER_BUSY_BACKOFF} // CONGESTION_CONTROL;

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
    $setup = OpenQA::Setup->new(log_name => 'scheduler');
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);

    OpenQA::Scheduler->new();
    log_debug("Scheduler started");
    log_debug("\t Scheduler default interval(ms) : " . SCHEDULE_TICK_MS);
    log_debug("\t Max job allocation: " . MAX_JOB_ALLOCATION);
    log_debug("\t Timeslot(ms) : " . TIMESLOT);
    log_debug("\t Wakeup on request : " . (WAKEUP_ON_REQUEST ? "enabled" : "disabled"));
    log_debug("\t Find job retries : " . FIND_JOB_ATTEMPTS);
    log_debug("\t Congestion control : " .                  (CONGESTION_CONTROL ? "enabled" : "disabled"));
    log_debug("\t Backoff when we can't schedule jobs : " . (BUSY_BACKOFF       ? "enabled" : "disabled"));
    log_debug("\t Capture loop avoidance(ms) : " . CAPTURE_LOOP_AVOIDANCE);
    log_debug("\t Max backoff(ms) : " . MAX_BACKOFF);

    my $reactor = Net::DBus::Reactor->main;
    OpenQA::Scheduler::Scheduler::reactor($reactor);
    $reactor->{timer}->{schedule_jobs} = $reactor->add_timeout(
        SCHEDULE_TICK_MS,
        Net::DBus::Callback->new(
            method => \&OpenQA::Scheduler::Scheduler::schedule
        ));
    $reactor->run;
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

dbus_method('wakeup_scheduler');
sub wakeup_scheduler {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::wakeup_scheduler();
}


1;
