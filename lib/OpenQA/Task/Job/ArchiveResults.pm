# Copyright 2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::ArchiveResults;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Time::Seconds;

sub register ($self, $app, @args) {
    $app->minion->add_task(archive_job_results => \&_archive_results);
}

sub _archive_results ($minion_job, @args) {
    my ($openqa_job_id) = @args;
    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;

    # avoid archiving during result cleanup, avoid running too many cleanup/archiving jobs in parallel
    return $minion_job->retry({delay => ONE_MINUTE})
      unless my $process_job_results_guard = $app->minion->guard('process_job_results_task', ONE_DAY, {limit => 5});
    return $minion_job->retry({delay => ONE_MINUTE})
      if $app->minion->is_locked('limit_results_and_logs_task');

    # avoid running any kind of result post processing task for a particular openQA job in parallel
    return $minion_job->retry({delay => 30})
      unless my $guard = $app->minion->guard("process_job_results_for_$openqa_job_id", ONE_DAY);

    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->finish("Job $openqa_job_id does not exist.") unless $openqa_job;
    $minion_job->note(archived_path => $openqa_job->archive);
}

1;
