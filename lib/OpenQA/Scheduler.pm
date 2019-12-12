# Copyright (C) 2015-2019 SUSE LLC
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
use Mojo::Base 'Mojolicious';

use OpenQA::Setup;
use Mojo::IOLoop;
use OpenQA::Utils 'log_debug';
use Mojo::Server::Daemon;
use OpenQA::Schema;
use OpenQA::Scheduler::Model::Jobs;

# Scheduler default clock. Defaults to 20 s
# Optimization rule of thumb is:
# if we see a enough big number of messages while in debug mode stating "Congestion control"
# we might consider touching this value, as we may have a very large cluster to deal with.
# To have a good metric: you might raise it just above as the maximum observed time
# that the scheduler took to perform the operations
use constant SCHEDULE_TICK_MS => $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} // 20000;

our $RUNNING;

sub startup {
    my $self = shift;

    OpenQA::Scheduler::Client::mark_current_process_as_scheduler;

    $self->_setup if $RUNNING;

    $self->defaults(appname => 'openQA Scheduler');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    $self->plugin('OpenQA::Shared::Plugin::Helpers');

    # The reactor interval might be set to 1 ms in case the scheduler has been woken up by the
    # web UI (In this case it is important to set it back to OpenQA::Scheduler::SCHEDULE_TICK_MS)
    OpenQA::Scheduler::Model::Jobs->singleton->on(
        conclude => sub {
            _reschedule(SCHEDULE_TICK_MS);
        });

    my $r = $self->routes;
    $r->namespaces(['OpenQA::Scheduler::Controller', 'OpenQA::Shared::Controller']);
    my $ca = $r->under('/')->to('Auth#check');
    $ca->get('/' => {json => {name => $self->defaults('appname')}});
    my $api = $ca->any('/api');
    $api->get('/wakeup')->to('API#wakeup');
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');

    OpenQA::Setup::setup_plain_exception_handler($self);
}

sub run {
    local $RUNNING = 1;
    __PACKAGE__->new->start;
}

sub wakeup { _reschedule(0) }

sub _reschedule {
    my $time = shift;

    # Allow manual scheduling
    return unless $RUNNING;

    # Reuse the existing timer if possible
    state $interval = SCHEDULE_TICK_MS;
    my $current = $interval;
    $interval = $time //= $current;
    state $timer;
    return if $interval == $current && $timer;

    log_debug("[rescheduling] Current tick is at $current ms. New tick will be in: $time ms");
    Mojo::IOLoop->remove($timer) if $timer;
    $timer = Mojo::IOLoop->recurring(($interval / 1000) => sub { OpenQA::Scheduler::Model::Jobs->singleton->schedule });
}

sub _setup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    # check for stale jobs every 2 minutes
    Mojo::IOLoop->recurring(
        120 => sub {
            OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs;
        });

    # initial schedule
    Mojo::IOLoop->next_tick(
        sub {
            log_debug("Scheduler default interval(ms): " . SCHEDULE_TICK_MS);
            log_debug("Max job allocation: " . OpenQA::Scheduler::Model::Jobs::MAX_JOB_ALLOCATION());
            OpenQA::Scheduler::Model::Jobs->singleton->schedule;
            _reschedule();
        });
}

1;
