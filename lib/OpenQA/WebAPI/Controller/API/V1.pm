# Copyright (C) 2014 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Controller::API::V1;
use Mojo::Base 'Mojolicious::Controller';

sub auth_jobtoken {
    my ($self)  = @_;
    my $headers = $self->req->headers;
    my $token   = $headers->header('X-API-JobToken');

    if ($token) {
        $self->app->log->debug("Received JobToken: $token");
        my $job = $self->schema->resultset('Jobs')->search(
            {'properties.key' => 'JOBTOKEN', 'properties.value' => $token},
            {columns          => ['id'],     join               => {worker => 'properties'}})->single;
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
