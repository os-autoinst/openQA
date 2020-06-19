# Copyright (C) 2019 SUSE LLC
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

package OpenQA::CacheService::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

sub info {
    my $self = shift;
    $self->render(json => $self->minion->stats);
}

sub status {
    my $self = shift;

    my $id = $self->param('id');
    return $self->render(json => {error => 'Specified job ID is invalid'}, status => 404)
      unless my $job = $self->minion->job($id);
    return $self->render(json => {error => 'Job info not available'}, status => 404)
      unless my $info = $job->info;
    my $status = {status => 'downloading'};

    # Our Minion job will finish early if another job is already downloading,
    # so we have to check if the lock has been released yet too
    my $processed = $info->{state} eq 'finished' || $info->{state} eq 'failed';
    if ($processed && !$self->progress->is_downloading($info->{notes}{lock})) {
        $status = {status => 'processed', result => $info->{result}, output => $info->{notes}{output}};

        # Output from the job that actually did the download
        my $id = $info->{notes}{downloading_job};
        if ($id && (my $job = $self->minion->job($id))) {
            if (my $info = $job->info) { $status->{output} = $info->{notes}{output} }
        }
    }

    $self->render(json => $status);
}

sub enqueue {
    my $self = shift;

    my $data = $self->req->json;
    return $self->render(json => {error => 'No task defined'}, status => 400)
      unless defined(my $task = $data->{task});
    return $self->render(json => {error => 'No arguments defined'}, status => 400)
      unless defined(my $args = $data->{args});
    return $self->render(json => {error => 'Arguments need to be an array'}, status => 400)
      unless ref $args eq 'ARRAY';
    return $self->render(json => {error => 'No lock defined'}, status => 400)
      unless defined(my $lock = $data->{lock});

    $self->app->log->debug("Requested [$task] Args: @{$args} Lock: $lock");

    my $id = $self->minion->enqueue($task => $args => {notes => {lock => $lock}});
    $self->render(json => {status => 'downloading', id => $id});
}

1;
