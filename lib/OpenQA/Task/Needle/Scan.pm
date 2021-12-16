# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::Scan;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Task::SignalGuard;
use OpenQA::Utils;
use Mojo::URL;

sub register ($self, $app, @args) {
    $app->minion->add_task(scan_needles => sub (@args) { _needles($app, @args) });
}

sub _needles ($app, $job, $args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

    # prevent multiple scan_needles tasks to run in parallel
    return $job->finish('Previous scan_needles job is still active')
      unless my $guard = $app->minion->guard('limit_scan_needles_task', 7200);

    my $dirs = $app->schema->resultset('NeedleDirs');

    while (my $dir = $dirs->next) {
        my $needles = $dir->needles;
        while (my $needle = $needles->next) {
            $needle->check_file;
            $needle->update;
        }
    }
    return;
}

1;
