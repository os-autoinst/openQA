# Copyright (C) 2015-2021 SUSE LLC
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
use OpenQA::Log qw(log_debug setup_log);
use Mojo::Server::Daemon;
use OpenQA::Schema;
use OpenQA::Scheduler::Model::Jobs;
use Scalar::Util qw(looks_like_number);

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

    # Provide help to users early to prevent failing later on misconfigurations
    return if $ENV{MOJO_HELP};

    OpenQA::Scheduler::Client::mark_current_process_as_scheduler;
    $self->setup if $RUNNING;
    $self->defaults(appname => 'openQA Scheduler');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    # Some plugins are shared between openQA micro services
    push @{$self->plugins->namespaces}, 'OpenQA::Shared::Plugin';
    $self->plugin('SharedHelpers');

    my $offset = OpenQA::Scheduler::Model::Jobs::STARVATION_PROTECTION_PRIORITY_OFFSET;
    die "OPENQA_SCHEDULER_STARVATION_PROTECTION_PRIORITY_OFFSET must be an integer >= 0\n"
      unless looks_like_number $offset && $offset >= 0;

    # The reactor interval might be set to 1 ms in case the scheduler has been woken up by the
    # web UI (In this case it is important to set it back to OpenQA::Scheduler::SCHEDULE_TICK_MS)
    OpenQA::Scheduler::Model::Jobs->singleton->on(
        conclude => sub {
            _reschedule(SCHEDULE_TICK_MS);
        });

    # Some controllers are shared between openQA micro services
    my $r = $self->routes->namespaces(['OpenQA::Shared::Controller', 'OpenQA::Scheduler::Controller']);

    my $ca = $r->under('/')->to('Auth#check');
    $ca->get('/' => {json => {name => $self->defaults('appname')}});
    my $api = $ca->any('/api');
    $api->get('/wakeup')->to('API#wakeup');

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

sub setup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    setup_log($self);

    # load Gru plugin to be able to enqueue finalize jobs when marking a job as incomplete
    push @{$self->plugins->namespaces}, 'OpenQA::Shared::Plugin';
    $self->plugin('Gru');

    # check for stale jobs every 2 minutes
    Mojo::IOLoop->recurring(120 => \&_check_stale);

    # initial schedule
    Mojo::IOLoop->next_tick(
        sub {
            log_debug("Scheduler default interval(ms): " . SCHEDULE_TICK_MS);
            log_debug("Max job allocation: " . OpenQA::Scheduler::Model::Jobs::MAX_JOB_ALLOCATION());
            OpenQA::Scheduler::Model::Jobs->singleton->schedule;
            _reschedule();
        });
}

sub schema { OpenQA::Schema->singleton }

# uncoverable statement
sub _check_stale { OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs }

1;
