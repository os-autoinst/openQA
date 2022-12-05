# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Bug::Limit;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry);
use OpenQA::Task::SignalGuard;
use Time::Seconds;

sub register ($self, $app, @) { $app->minion->add_task(limit_bugs => \&_limit) }

sub _limit ($job) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $app = $job->app;

    # prevent multiple limit_bugs tasks to run in parallel
    return $job->finish('Previous limit_bugs job is still active')
      unless my $guard = $app->minion->guard('limit_bugs_task', ONE_DAY);

    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    # cleanup entries in the bug table that are not referenced from any comments
    my $bugrefs = $app->schema->resultset('Comments')->referenced_bugs;
    my %cleaned;
    for my $bug ($app->schema->resultset('Bugs')->all) {
        next if defined $bugrefs->{$bug->bugid};
        $bug->delete;
        $cleaned{$bug->id} = $bug->bugid;
    }
    $app->emit_event('openqa_bugs_cleaned', {deleted => scalar(keys(%cleaned))});
    $job->note(bugs_cleaned => \%cleaned);
}

1;
