# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::FinalizeResults;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Jobs::Constants qw(CANCELLED DONE);
use OpenQA::Task::SignalGuard;
use Time::Seconds;
use Feature::Compat::Try;

sub register ($self, $app, @) {
    $app->minion->add_task(finalize_job_results => \&_finalize_results);
}

sub _finalize_results ($minion_job, $openqa_job_id = undef, $carried_over = undef, $initial_state = undef) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($minion_job);
    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;
    return $minion_job->retry({delay => 30})
      unless my $guard = $app->minion->guard("process_job_results_for_$openqa_job_id", ONE_DAY);

    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->finish("Job $openqa_job_id does not exist.") unless $openqa_job;

    # try to finalize each
    my %failed_to_finalize;
    for my $module ($openqa_job->modules_with_job_prefetched) {
        try { $module->finalize_results }
        catch ($e) { $failed_to_finalize{$module->name} = $e }
    }

    # record failed modules
    if (keys %failed_to_finalize) {
        my $count = scalar keys %failed_to_finalize;
        $minion_job->note(failed_modules => \%failed_to_finalize);
        $minion_job->fail("Finalizing results of $count modules failed");
    }

    # invoke hook script
    if ($openqa_job->state ne CANCELLED && ($initial_state // '') ne DONE && !$carried_over) {
        _run_hook_script($minion_job, $openqa_job, $app, $ensure_task_retry_on_termination_signal_guard);
        $app->minion->enqueue($_ => []) for @{$app->config->{minion_task_triggers}->{on_job_done}};
    }
}

sub _run_hook_script ($minion_job, $openqa_job, $app, $guard) {
    return undef unless my $hook = $openqa_job->hook_script;

    my $timeout = $ENV{OPENQA_JOB_DONE_HOOK_TIMEOUT} // '5m';
    my $kill_timeout = $ENV{OPENQA_JOB_DONE_HOOK_KILL_TIMEOUT} // '30s';
    my $settings = $openqa_job->settings_hash;
    my $delay = $settings->{_TRIGGER_JOB_DONE_DELAY} // $ENV{OPENQA_JOB_DONE_HOOK_DELAY} // ONE_MINUTE;
    # Linear backoff with 53 retries ~ 1 day
    my $retries = $settings->{_TRIGGER_JOB_DONE_RETRIES} // $ENV{OPENQA_JOB_DONE_HOOK_RETRIES} // 53;
    my $skip_rc = $settings->{_TRIGGER_JOB_DONE_SKIP_RC} // $ENV{OPENQA_JOB_DONE_HOOK_SKIP_RC} // 142;
    $guard->retry(0);
    my $id = $app->minion->enqueue(
        hook_script => [
            $hook,
            $openqa_job->id,
            {
                timeout => $timeout,
                kill_timeout => $kill_timeout,
                delay => $delay,
                retries => $retries,
                skip_rc => $skip_rc
            }]);
    $minion_job->note(hook_job => $id);
}

1;
