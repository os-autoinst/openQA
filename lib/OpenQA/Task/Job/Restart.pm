# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::Restart;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Time::Seconds;
use OpenQA::Events;

sub register ($self, $app, @args) {
    $app->minion->add_task(restart_job => \&_restart_job);
}

sub restart_attempts { $ENV{OPENQA_JOB_RESTART_ATTEMPTS} // 5 }

sub restart_delay { $ENV{OPENQA_JOB_RESTART_DELAY} // 5 }

sub restart_openqa_job ($minion_job, $openqa_job) {
    my $cloned_job_or_error = $openqa_job->auto_duplicate;
    my $is_ok = ref $cloned_job_or_error || $cloned_job_or_error =~ qr/(already.*clone|direct parent)/i;
    if (ref $cloned_job_or_error) {
        my %event_data = (id => $openqa_job->id, result => $cloned_job_or_error->{cluster_cloned}, auto => 1);
        OpenQA::Events->singleton->emit_event('openqa_job_restart', data => \%event_data);
    }

    $minion_job->note(
        ref $cloned_job_or_error
        ? (cluster_cloned => $cloned_job_or_error->{cluster_cloned})
        : (restart_error => $cloned_job_or_error));
    return ($is_ok, $cloned_job_or_error);
}

sub _restart_job ($minion_job, @args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($minion_job);

    my ($openqa_job_id) = @args;
    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;
    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->finish("Job $openqa_job_id does not exist.") unless $openqa_job;

    _init_amqp_plugin($app);
    # duplicate job and finish normally if no error was returned or job can not be cloned
    my ($is_ok, $cloned_job_or_error) = restart_openqa_job($minion_job, $openqa_job);
    _wait_for_event_publish($app);

    return $minion_job->finish(ref $cloned_job_or_error ? undef : $cloned_job_or_error) if $is_ok;

    # retry a certain number of times, maybe the transaction failed due to a conflict
    my $failures = $minion_job->info->{notes}->{failures};
    $failures = $failures ? ($failures + 1) : (1);
    my $max_attempts = restart_attempts;
    return $minion_job->fail($cloned_job_or_error) if $failures >= $max_attempts;
    $minion_job->note(failures => $failures, last_failure => $cloned_job_or_error);
    $minion_job->retry({delay => restart_delay});
}

sub _init_amqp_plugin ($app) {
    return undef unless $app->config->{amqp}->{enabled};
    $app->plugin('AMQP');    # Needs to be loaded again from forked process
    Mojo::IOLoop->singleton->one_tick;
}

sub _wait_for_event_publish ($app) {
    return undef unless $app->config->{amqp}->{enabled};
    OpenQA::Events->singleton->once(amqp_handled => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
}

1;
