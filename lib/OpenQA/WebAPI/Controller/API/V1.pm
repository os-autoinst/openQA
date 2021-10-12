# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1;
use Mojo::Base 'Mojolicious::Controller';

sub auth_jobtoken {
    my ($self) = @_;
    my $headers = $self->req->headers;
    my $token = $headers->header('X-API-JobToken');

    if ($token) {
        $self->app->log->debug("Received JobToken: $token");
        my $job = $self->schema->resultset('Jobs')->search(
            {'properties.key' => 'JOBTOKEN', 'properties.value' => $token},
            {columns => ['id'], join => {worker => 'properties'}})->single;
        if ($job) {
            $self->stash('job_id', $job->id);
            $self->app->log->debug(sprintf('Found associated job %u', $job->id));
            return 1;
        }
    }
    else {
        $self->app->log->warn('No JobToken received!');
    }
    $self->render(json => {error => 'invalid jobtoken'}, status => 403);
    return;
}

1;
