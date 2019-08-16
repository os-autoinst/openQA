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

package OpenQA::WebAPI::Plugin::ObsRsync::Gru;
use Mojo::Base 'OpenQA::WebAPI::Plugin::ObsRsync::Controller';
use IPC::System::Simple qw(system $EXITVAL);
use POSIX 'strftime';
use Data::Dump qw/dump/;

# These constants are used in reply to rsync request.
#
# Normal reply should be STARTED, meaning that job shall run immediatelly or soon
# (honouring `concurrency` configuration). (I.e. job `obs_rsync_run` has been created).
#
# If new request comes for a project which already has rsync running - the response will be QUEUED,
# meaning that rsync for the project will be attempted again once active rsync is finished.
# (I.e. job `obs_rsync_queue` is created, which later will create job `obs_rsync_run`).
#
# Response IN_QUEUE means that no new job was created, because the project has another job already scheduled.
# IN_QUEUE may happen in two cases:
# * the project has job which is already QUEUED (i.e. has task `obs_rsync_queue`)
# * the project is STARTED, but is waiting for concurrency slot
# (i.e. has task `obs_rsync_run` with note {waitingconcurrencyslot=>1})
#
# QUEUE_FULL means that number of non-finished jobs for tasks 'obs_rsync_queue' and 'obs_rsync_run'
# reached parameter `queue_limit`.
# This condition shouldn't practically happen and means either overload or some bug in queueing.
#
# Code below does not have strong concurrency guards, but in worst case it should lead to project queued
# twice, which shouldn't be a problem.
use constant {
    QUEUED     => 200,
    STARTED    => 201,
    IN_QUEUE   => 208,
    QUEUE_FULL => 507,
};

my $lock_timeout = 36000;

sub register_tasks {
    my ($app) = @_;
    my $home = $app->config->{obs_rsync}->{home};
    return undef unless $home;

    my $minion = $app->minion;
    $minion->add_task(obs_rsync_queue => sub { return _queue($app, @_) });
    $minion->add_task(obs_rsync_run   => sub { return _run($app, @_) });
}

sub index {
    my $self = shift;
    my %jobs;
    my $results = $self->app->minion->backend->list_jobs(0, 400,
        {tasks => ['obs_rsync_run', 'obs_rsync_queue'], states => ['active', 'inactive']});

    for my $job (@{$results->{jobs}}) {
        $jobs{$job->{id}} = _extend_job_info($job);
    }

    $self->render('ObsRsync_gru_index', jobs => \%jobs);
}

sub _extend_job_info {
    my ($job) = @_;
    my $created_at = $job->{created};
    $created_at = strftime("%Y-%m-%d %H:%M:%S %z", localtime($created_at)) if $created_at;
    my $started_at = $job->{started};
    $started_at = strftime("%Y-%m-%d %H:%M:%S %z", localtime($started_at)) if $started_at;
    my $info = {
        id       => $job->{id},
        task     => $job->{task},
        args     => dump($job->{args}),
        created  => $created_at,
        started  => $started_at,
        priority => $job->{priority},
        retries  => $job->{retries},
        state    => $job->{state},
        notes    => dump($job->{notes}),
    };
    return $info;
}

sub run {
    my $self    = shift;
    my $project = $self->param('folder');
    return undef if $self->_check_and_render_error($project);
    my $app         = $self->app;
    my $queue_limit = $app->obs_rsync->queue_limit;

    my $results = $app->minion->backend->list_jobs(
        0,
        4 * $queue_limit,
        {tasks => ['obs_rsync_run', 'obs_rsync_queue'], states => ['active', 'inactive']});

    for my $other_job (@{$results->{jobs}}) {
        if ($other_job->{args} && ($other_job->{args}[0]->{project} eq $project)) {

            return $self->render(json => {message => $project . ' already in queue'}, status => IN_QUEUE)
              if ($other_job->{task} eq 'obs_rsync_queue' || $other_job->{notes}{waitingconcurrencyslot});
            $app->gru->enqueue('obs_rsync_queue', {project => $project}, {priority => 90});
            return $self->render(json => {message => "ok"}, status => QUEUED);
        }
    }
    return $self->render(json => {message => 'queue full'}, status => QUEUE_FULL)
      if ($results->{total} >= $queue_limit);

    $app->gru->enqueue(
        'obs_rsync_run',
        {project  => $project},
        {priority => 100, notes => {waitingconcurrencyslot => 1}});
    return $self->render(json => {message => 'started'}, status => STARTED);
}

sub _queue {
    my ($app, $job, $args) = @_;
    my $project        = $args->{project};
    my $retry_interval = $app->obs_rsync->retry_interval;
    my $queue_limit    = $app->obs_rsync->queue_limit;


    my $results = $app->minion->backend->list_jobs(
        0,
        4 * $queue_limit,
        {tasks => ['obs_rsync_run'], states => ['active', 'inactive']});
    for my $other_job (@{$results->{jobs}}) {
        if ($other_job->{args} && ($other_job->{args}[0]->{project} eq $project)) {
            return $job->finish(IN_QUEUE) if $other_job->{notes}{waitingconcurrencyslot};
            return $job->retry({delay => $retry_interval});
        }
    }
    $app->gru->enqueue(
        'obs_rsync_run',
        {project  => $project},
        {priority => 100, notes => {waitingconcurrencyslot => 1}});
    return $job->finish(STARTED);
}

sub _run {
    my ($app, $job, $args) = @_;
    my $project            = $args->{project};
    my $home               = $app->obs_rsync->home;
    my $concurrency        = $app->obs_rsync->concurrency;
    my $project_status_url = $app->obs_rsync->project_status_url;
    my $retry_interval     = $app->obs_rsync->retry_interval;
    my $queue_limit        = $app->obs_rsync->queue_limit;

    return $job->retry({delay => $retry_interval}) if $app->obs_project->is_status_dirty($project_status_url, $project);
    return $job->retry({delay => $retry_interval})
      unless my $guard = $app->minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $concurrency});

    $job->note(waitingconcurrencyslot => undef);
    eval { system([0], "bash", "$home/rsync.sh", $project); };
    return $job->finish($EXITVAL);
}

1;
