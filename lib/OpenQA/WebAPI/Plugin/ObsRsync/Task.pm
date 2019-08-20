# Copyright (C) 2019 SUSE Linux GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Plugin::ObsRsync::Task;
use Mojo::Base -strict;
use IPC::System::Simple qw(system $EXITVAL);

my $lock_timeout = 36000;

sub _run {
    my ($app, $job, $args) = @_;
    my $project        = $args->{project};
    my $helper         = $app->obs_rsync;
    my $home           = $helper->home;
    my $concurrency    = $helper->concurrency;
    my $retry_interval = $helper->retry_interval;
    my $queue_limit    = $helper->queue_limit;
    my $minion         = $app->minion;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return $job->retry({delay => $retry_interval})
          unless $minion->lock("obs_rsync_project_" . $project . "_lock", $lock_timeout);

        $job->note(project_lock => 1);
    }
    return $job->retry({delay => $retry_interval}) if $helper->is_status_dirty($project);

    return $job->retry({delay => $retry_interval})
      unless my $concurrency_guard = $minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $concurrency});

    my $error;
    eval { system([0], "bash", "$home/rsync.sh", $project); 1; } or do {
        $error = $@ || 'No message';
        $app->log->error("ObsRsync#_run failed: " . $EXITVAL . " " . $error);
    };
    $minion->unlock("obs_rsync_project_" . $project . "_lock");
    if ($EXITVAL) {
        return $job->fail({code => $EXITVAL, message => $error});
    }
    return $job->finish(0);
}

1;
