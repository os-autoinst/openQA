# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::CreateZipArchive;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Archive;
use Feature::Compat::Try;
use Time::Seconds;

sub register ($self, $app, @args) {
    $app->minion->add_task(create_zip_archive => \&_create_zip_archive);
}

sub _create_zip_archive ($minion_job, $job_id) {
    my $app = $minion_job->app;

    # avoid running too many archive generation jobs in parallel
    return $minion_job->retry({delay => ONE_MINUTE})
      unless my $guard = $app->minion->guard('create_zip_archive_task', ONE_DAY, {limit => 2});

    my $job = $app->schema->resultset('Jobs')->find($job_id);
    unless ($job) {
        $minion_job->finish("Job $job_id not found");
        return;
    }
    try {
        OpenQA::Archive::create_job_archive($job);
        $minion_job->finish;
    }
    catch ($e) {
        $minion_job->fail("Failed to create archive: $e");
    }
}

1;
