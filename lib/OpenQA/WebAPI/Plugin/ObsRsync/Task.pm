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
    my $home           = $app->obs_rsync->home;
    my $concurrency    = $app->obs_rsync->concurrency;
    my $retry_interval = $app->obs_rsync->retry_interval;
    my $queue_limit    = $app->obs_rsync->queue_limit;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return $job->retry({delay => $retry_interval})
          unless $app->minion->lock("obs_rsync_project_" . $project . "_lock", $lock_timeout);

        $job->note(project_lock => 1);
    }
    return $job->retry({delay => $retry_interval}) if $app->obs_project->is_status_dirty($project);

    return $job->retry({delay => $retry_interval})
      unless my $concurrency_guard = $app->minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $concurrency});

    eval { system([0], "bash", "$home/rsync.sh", $project); };
    $app->minion->unlock("obs_rsync_project_" . $project . "_lock");
    return $job->finish($EXITVAL);
}

1;
