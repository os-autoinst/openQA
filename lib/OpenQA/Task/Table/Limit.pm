# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Table::Limit;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry);
use OpenQA::Task::SignalGuard;
use Time::Seconds;

has 'task_name';
has 'table';

sub register ($self, $app, @) { $app->minion->add_task($self->task_name => sub { $self->_limit($app, @_) }) }

sub _limit ($self, $app, $job, @) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

    # prevent multiple limit tasks to run in parallel
    my $task_name = $self->task_name;
    my $guard = $app->minion->guard("${task_name}_task", ONE_DAY);
    return $job->finish("Previous $task_name job is still active") unless $guard;
    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    $app->schema->resultset($self->table)->delete_entries_exceeding_storage_duration;
}

1;
