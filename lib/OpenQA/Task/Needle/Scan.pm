# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::Scan;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Task::SignalGuard;
use OpenQA::Utils;
use Mojo::URL;

sub register ($self, $app, $job) {
    $app->minion->add_task(scan_needles => sub ($job) { _needles($app, $job) });
}

sub _needles ($app, $job) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

    # prevent multiple scan_needles tasks to run in parallel
    return $job->finish('Previous scan_needles job is still active')
      unless my $guard = $app->minion->guard('limit_scan_needles_task', 7200);
    for my $dir ($app->schema->resultset('NeedleDirs')->all) {
        for my $needle ($dir->needles->all) {
            $needle->check_file;
            $needle->update;
        }
    }
    return;
}

1;
