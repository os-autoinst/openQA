# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub auth_jobtoken ($self) {
    $self->render(json => {error => 'no JobToken received'}, status => 403) && return
      unless my $token = $self->req->headers->header('X-API-JobToken');
    $self->render(json => {error => 'invalid jobtoken'}, status => 403) && return
      unless my $job = $self->schema->resultset('Jobs')->search(
        {'properties.key' => 'JOBTOKEN', 'properties.value' => $token},
        {columns => ['id'], join => {worker => 'properties'}})->single;
    $self->stash('job_id', $job->id);
    $self->app->log->trace('Found associated job ' . $job->id);
    return 1;
}

1;
