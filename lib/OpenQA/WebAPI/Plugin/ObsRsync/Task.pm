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
use Mojo::File;
use IPC::Run;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(obs_rsync_run                 => \&run);
    $app->minion->add_task(obs_rsync_update_dirty_status => \&update_dirty_status);
    $app->minion->add_task(obs_rsync_update_obs_version  => \&update_obs_version);
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
    my $lock_timeout   = 360000;

    my $retry_interval_on_exception = 120;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return $job->retry({delay => $retry_interval})
          unless $minion->lock('obs_rsync_project_' . $project . '_lock', $lock_timeout);

        $job->note(project_lock => 1);
    }
    my $dirty = 0;
    eval { $dirty = $helper->is_status_dirty($project, 1); 1 } or $job->retry({delay => $retry_interval_on_exception});
    return $job->retry({delay => $retry_interval}) if $dirty;

    return $job->retry({delay => $retry_interval})
      unless my $concurrency_guard = $minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $concurrency});

    $helper->log_job_id($project, $job->id);
    my @cmd = (Mojo::File->new($home, 'script', 'rsync.sh')->to_string, $project);
    my ($stdin, $stdout, $error);
    IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error);
    my $exit_code = $?;
    $minion->unlock('obs_rsync_project_' . $project . '_lock');
    return $job->finish(0) if (!$exit_code);

    $error ||= 'No message';
    $error =~ s/\s+$//;
    $app->log->error('ObsRsync#_run failed (' . $exit_code . '): ' . $error);
    $helper->log_failure($project, $job->id);
    return $job->fail({code => $exit_code, message => $error});
}

sub update_dirty_status {
    my ($job, $args) = @_;

    my $app     = $job->app;
    my $project = $args->{project};
    my $helper  = $app->obs_rsync;
    eval { $helper->is_status_dirty($project, 1); 1 };
    return $job->finish(0);
}

sub update_obs_version {
    my ($job, $args) = @_;

    my $app          = $job->app;
    my $project      = $args->{project};
    my $helper       = $app->obs_rsync;
    my $lock_timeout = 120;

    my $read_files = Mojo::File->new($helper->home, $project, 'read_files.sh');
    return $job->finish("Cannot find $read_files") unless -f $read_files;

    my $project_lock = Mojo::File->new($helper->home, $project, 'rsync.lock');
    return $job->finish("File exists $project_lock") if -f $project_lock;

    my $gru_project_lock = 'obs_rsync_project_' . $project . '_lock';
    my $guard            = $app->minion->guard($gru_project_lock, $lock_timeout);
    return $job->finish('Gru lock exists') unless $guard;

    my @cmd = ("bash", $read_files);
    my ($stdin, $stdout, $error);
    IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error);
    my $exit_code = $?;
    return $job->finish('Success') if (!$exit_code);

    return $job->fail({code => $exit_code, message => $error});
}

1;
