# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::CreateZipArchive;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Archive;
use Feature::Compat::Try;

sub register ($self, $app, @args) {
    $app->minion->add_task(create_zip_archive => \&_create_zip_archive);
}

sub _create_zip_archive ($minion_job, $job_id) {
    my $app = $minion_job->app;
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
