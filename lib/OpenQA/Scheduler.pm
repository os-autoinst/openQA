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
use OpenQA::Scheduler::Model::Jobs;

# Scheduler default clock. Defaults to 20 s
# Optimization rule of thumb is:
# if we see a enough big number of messages while in debug mode stating "Congestion control"
# we might consider touching this value, as we may have a very large cluster to deal with.
# To have a good metric: you might raise it just above as the maximum observed time
# that the scheduler took to perform the operations
use constant SCHEDULE_TICK_MS => $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} // 20000;

our $RUNNING;

sub run {
    my $self   = __PACKAGE__->new;
    my $daemon = $self->setup;
    local $RUNNING = 1;
    $daemon->run;
}

sub setup {
    my $self = shift;

    my $setup = OpenQA::Setup->new(log_name => 'scheduler');
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);

    log_debug("Scheduler started");
    log_debug("\t Scheduler default interval(ms) : " . SCHEDULE_TICK_MS);
    log_debug("\t Max job allocation: " . OpenQA::Scheduler::Model::Jobs::MAX_JOB_ALLOCATION());

    # initial schedule
    OpenQA::Scheduler::Model::Jobs->singleton->schedule;
    Mojo::IOLoop->next_tick(sub { _reschedule() });

    return Mojo::Server::Daemon->new(app => $self);
}

sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Scheduler');
    $self->mode('production');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    # The reactor interval might be set to 1 ms in case the scheduler has been woken up by the
    # web UI (In this case it is important to set it back to OpenQA::Scheduler::SCHEDULE_TICK_MS)
    OpenQA::Scheduler::Model::Jobs->singleton->on(
        conclude => sub {
            _reschedule(SCHEDULE_TICK_MS);
        });

    my $r = $self->routes;
    $r->get(
        '/api/wakeup' => sub {
            my $c = shift;
            _reschedule(0);
            $c->render(text => 'ok');
        });
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');
}

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

1;
