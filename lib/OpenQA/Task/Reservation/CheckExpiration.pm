# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Reservation::CheckExpiration;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::SignalGuard;
use OpenQA::Events;
use Time::Seconds;

sub register ($self, $app, @args) { $app->minion->add_task(check_reservation_expiration => \&_check_expiration) }

sub _check_expiration ($job) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $app = $job->app;

    # prevent multiple check_reservation_expiration tasks from running in parallel
    return $job->finish('Previous check_reservation_expiration job is still active')
      unless my $guard = $app->minion->guard('check_reservation_expiration_task', ONE_HOUR);

    my $now = time;
    my $config = $app->config->{worker_reservation} // {};
    my $threshold = $config->{expiration_warning_threshold} // 1800;    # default to 30 mins (1800 seconds)

    my @workers = $app->schema->resultset('Workers')->all;
    my @expiring;
    for my $worker (@workers) {
        next unless $worker->is_reserved;
        my $properties = $worker->_reservation_properties;
        my $expires = $properties->{RESERVED_T_EXPIRES};
        next if !$expires;    # indefinite
        my $time_left = $expires - $now;
        if ($time_left > 0 && $time_left <= $threshold) {
            push @expiring,
              {
                id => $worker->id,
                name => $worker->name,
                user => $worker->_reserved_by_name,
                comment => $properties->{RESERVED_COMMENT},
                time_left => $time_left,
              };
        }
    }

    if (@expiring) {
        my $system_user = $app->schema->resultset('Users')->find({username => 'system'});
        my $user_id = $system_user ? $system_user->id : undef;
        OpenQA::Events->singleton->emit_event(
            'openqa_worker_reservation_expiring',
            user_id => $user_id,
            connection_id => 0,
            data => {workers => \@expiring});
    }

    $job->finish({notified => scalar @expiring});
}

1;
