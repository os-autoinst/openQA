# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::AuditEvents::Limit;
use Mojo::Base 'Mojolicious::Plugin';
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry);
use Time::Seconds;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_audit_events => sub { _limit($app, @_) });
}

sub _limit {
    my ($app, $job) = @_;

    # prevent multiple limit_audit_events tasks to run in parallel
    return $job->finish('Previous limit_audit_events job is still active')
      unless my $guard = $app->minion->guard('limit_audit_events_task', ONE_DAY);

    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    $app->schema->resultset('AuditEvents')->delete_entries_exceeding_storage_duration;
}

1;
