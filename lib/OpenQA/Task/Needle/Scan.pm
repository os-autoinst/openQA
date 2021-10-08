# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::Scan;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(scan_needles => sub { _needles($app, @_) });
}

sub _needles {
    my ($app, $job, $args) = @_;

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
