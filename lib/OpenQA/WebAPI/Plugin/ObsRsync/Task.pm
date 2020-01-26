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
    $app->minion->add_task(obs_rsync_update_builds_text  => \&update_obs_builds_text);
}

sub run {
    my ($job, $args) = @_;

    my $app            = $job->app;
    my $project        = $args->{project};
    my $helper         = $app->obs_rsync;
    my $home           = $helper->home;
    my $retry_interval = $helper->retry_interval;
    my $queue_limit    = $helper->queue_limit;

    my $retry_interval_on_exception = 120;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return $job->retry({delay => $retry_interval})
          unless $helper->lock($project);

        $job->note(project_lock => 1);
    }
    my $dirty = 0;
    eval { $dirty = $helper->is_status_dirty($project, 1); 1 } or $job->retry({delay => $retry_interval_on_exception});
    return $job->retry({delay => $retry_interval}) if $dirty;

    return $job->retry({delay => $retry_interval})
      unless my $concurrency_guard = $helper->concurrency_guard();

    $helper->log_job_id($project, $job->id);
    my @cmd = (Mojo::File->new($home, 'script', 'rsync.sh')->to_string, $project);
    my ($stdin, $stdout, $error);
    my $exit_code = -1;
    eval { IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error); $exit_code = $?; };
    my $error_from_exception = $@;

    $helper->unlock($project);
    return $job->finish(0) if (!$exit_code);

    $error ||= $error_from_exception;
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

sub update_obs_builds_text {
    my ($job, $args) = @_;

    my $app    = $job->app;
    my $alias  = $args->{alias};
    my $helper = $app->obs_rsync;

    my ($project, undef) = $helper->split_alias($alias);
    # this lock indicates that rsync.sh have started - it is dangerous to call read_files.sh
    my $project_lock = Mojo::File->new($helper->home, $project, 'rsync.lock');
    return $job->finish("File exists $project_lock") if -f $project_lock;

    # this lock indicates that Gru job for project is active - it is dangerous to call read_files.sh
    my $guard = $helper->guard($project);
    return $job->finish('Gru lock exists') unless $guard;

    my $sub = sub {
        my (undef, $batch) = @_;
        my $read_files = Mojo::File->new($helper->home, $project, $batch, 'read_files.sh');
        return $job->finish("Cannot find $read_files") unless -f $read_files;

        my @cmd = ("bash", $read_files);
        my ($stdin, $stdout, $error);
        my $exit_code = -1;
        eval { IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error); $exit_code = $?; };
        my $err = $@;
        return ($exit_code, $error // $err);
    };

    my ($exit_code, $error) = $helper->for_every_batch($alias, $sub);

    return $job->fail({code => $exit_code, message => $error}) if !$exit_code;
    return $job->finish('Success');
}

1;
