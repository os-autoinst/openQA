# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::HookScript;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::SignalGuard;

sub register ($self, $app, $config) {
    $app->minion->add_task(hook_script => \&_hook_script);
}

sub _hook_script ($job, $hook, $openqa_job_id, $options) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $timeout = $options->{timeout};
    my $kill_timeout = $options->{kill_timeout};
    my $retries = $options->{retries};
    my $delay = $options->{delay} * ($job->retries + 1);
    my $skip_rc = $options->{skip_rc};

    $ensure_task_retry_on_termination_signal_guard->abort(1);
    my ($rc, $out) = _run_hook($hook, $openqa_job_id, $timeout, $kill_timeout);
    $job->note(hook_cmd => $hook, hook_result => $out, hook_rc => $rc);

    if ($retries && $skip_rc && defined $rc && $rc == $skip_rc && $job->retries < $retries) {
        $job->app->log->debug("Job @{[$job->id]}: Retrying @{[$job->retries]} times with linear delay: ${delay}s");
        $job->retry($delay ? {delay => $delay} : {});
    }
}

sub _run_hook ($hook, $openqa_job_id, $timeout, $kill_timeout) {
    my $out = qx{timeout -v --kill-after="$kill_timeout" "$timeout" $hook $openqa_job_id};
    return ($? >> 8, $out);
}

1;
