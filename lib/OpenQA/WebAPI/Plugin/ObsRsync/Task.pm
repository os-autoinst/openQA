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
use Mojo::Base 'Mojolicious::Plugin';

use IPC::Run;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(obs_rsync_run => \&run);
}

sub run {
    my ($job, $args) = @_;

    my $app            = $job->app;
    my $project        = $args->{project};
    my $helper         = $app->obs_rsync;
    my $home           = $helper->home;
    my $concurrency    = $helper->concurrency;
    my $retry_interval = $helper->retry_interval;
    my $queue_limit    = $helper->queue_limit;
    my $minion         = $app->minion;
    my $lock_timeout   = 36000;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return $job->retry({delay => $retry_interval})
          unless $minion->lock('obs_rsync_project_' . $project . '_lock', $lock_timeout);

        $job->note(project_lock => 1);
    }
    return $job->retry({delay => $retry_interval}) if $helper->is_status_dirty($project);

    return $job->retry({delay => $retry_interval})
      unless my $concurrency_guard = $minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $concurrency});

    my @cmd = ('bash', "$home/rsync.sh", $project);
    my ($stdin, $stdout, $error);
    IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error);
    my $exit_code = $?;
    $minion->unlock('obs_rsync_project_' . $project . '_lock');
    return $job->finish(0) if (!$exit_code);

    $error ||= 'No message';
    $error =~ s/\s+$//;
    $app->log->error('ObsRsync#_run failed (' . $exit_code . '): ' . $error);
    return $job->fail({code => $exit_code, message => $error});
}

1;
