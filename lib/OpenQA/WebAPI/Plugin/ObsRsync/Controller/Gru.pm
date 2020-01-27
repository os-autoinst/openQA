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

package OpenQA::WebAPI::Plugin::ObsRsync::Controller::Gru;
use Mojo::Base 'Mojolicious::Controller';
use POSIX 'strftime';
use Data::Dump qw/dump/;

# These constants are used in reply to rsync request.
#
# Normal reply should be STARTED, meaning that job shall run immediately or soon
# (honouring `concurrency` configuration). (I.e. job `obs_rsync_run` has been created).
#
# If new request comes for a project which already has rsync running - the response will be QUEUED,
# meaning that rsync for the project will be attempted again once active rsync is finished.
# (I.e. job `obs_rsync_run` is created, but will it will be postponed until current rsync finishes).
#
# Response IN_QUEUE means that no new job was created, because the project has another job already scheduled.
# IN_QUEUE happens when the project has another job which is already QUEUED
# (i.e. has task `obs_rsync_run` in 'inactive' state)
#
# QUEUE_FULL means that number of non-finished jobs for tasks 'obs_rsync_run' reached parameter `queue_limit`.
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

sub index {
    my $self   = shift;
    my $helper = $self->obs_rsync;
    my %jobs;
    my $results = $self->app->minion->backend->list_jobs(
        0,
        4 * $helper->queue_limit,
        {tasks => ['obs_rsync_run'], states => ['active', 'inactive']});

    for my $job (@{$results->{jobs}}) {
        $jobs{$job->{id}} = _extend_job_info($job);
    }

    $self->render('ObsRsync_gru_index', jobs => \%jobs);
}

# this prepares fields for rendering
sub _extend_job_info {
    my ($job) = @_;

    my $created_at = $job->{created};
    $created_at = strftime('%Y-%m-%d %H:%M:%S %z', localtime($created_at)) if $created_at;

    my $started_at = $job->{started};
    $started_at = strftime('%Y-%m-%d %H:%M:%S %z', localtime($started_at)) if $started_at;

    my $args = $job->{args};
    $args = $args->[0] if (ref $args eq 'ARRAY' && scalar(@$args) == 1);
    if (ref $args eq 'HASH' && scalar(%$args) == 1 && $args->{project}) {
        $args = $args->{project};
    }
    else {
        $args = dump($args);
    }
    my $info = {
        id       => $job->{id},
        task     => $job->{task},
        args     => $args,
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
    my $project = $self->param('project');
    my $helper  = $self->obs_rsync;
    return undef if $helper->check_and_render_error($project);
    my $app         = $self->app;
    my $queue_limit = $helper->queue_limit;

    my $results = $app->minion->backend->list_jobs(
        0,
        4 * $queue_limit,
        {tasks => ['obs_rsync_run'], states => ['active', 'inactive']});

    my $has_active_job = 0;
    for my $job (@{$results->{jobs}}) {
        if ($job->{args} && ($job->{args}[0]->{project} eq $project)) {
            return $self->render(json => {message => $project . ' already in queue'}, status => IN_QUEUE)
              if (!$job->{notes}{project_lock} || $job->{state} eq 'inactive');

            $has_active_job = 1;
        }
    }
    return $self->render(json => {message => 'queue full'}, status => QUEUE_FULL)
      if ($results->{total} >= $queue_limit);

    $app->gru->enqueue('obs_rsync_run', {project => $project}, {priority => 100});
    if ($has_active_job) {
        return $self->render(json => {message => 'queued'}, status => QUEUED);
    }
    return $self->render(json => {message => 'started'}, status => STARTED);
}

sub get_dirty_status {
    my $self    = shift;
    my $project = $self->param('project');
    my $helper  = $self->obs_rsync;
    return undef if $helper->check_and_render_error($project);

    return $self->render(json => {message => $helper->get_dirty_status($project)}, status => 200);
}

sub update_dirty_status {
    my $self    = shift;
    my $project = $self->param('project');
    return undef if $self->obs_rsync->check_and_render_error($project);

    $self->app->gru->enqueue('obs_rsync_update_dirty_status', {project => $project});
    return $self->render(json => {message => 'started'}, status => 200);
}

sub get_obs_builds_text {
    my $self   = shift;
    my $alias  = $self->param('alias');
    my $helper = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias);

    return $self->render(json => {message => $helper->get_obs_builds_text($alias)}, status => 200);
}

sub update_obs_builds_text {
    my $self  = shift;
    my $alias = $self->param('alias');
    return undef if $self->obs_rsync->check_and_render_error($alias);

    $self->app->gru->enqueue('obs_rsync_update_builds_text', {alias => $alias});
    return $self->render(json => {message => 'started'}, status => 200);
}

1;
