# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::AuditEvents::Limit;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry);
use OpenQA::Task::SignalGuard;
use Time::Seconds;

sub register ($self, $app, @args) {
    $app->minion->add_task(limit_audit_events => sub { _limit($app, @args) });
}

sub _limit ($app, $job) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    # prevent multiple limit_audit_events tasks to run in parallel
    return $job->finish('Previous limit_audit_events job is still active')
      unless my $guard = $app->minion->guard('limit_audit_events_task', ONE_DAY);

    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    $app->schema->resultset('AuditEvents')->delete_entries_exceeding_storage_duration;
}

1;
