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

use OpenQA::CacheService::Model::Cache qw(STATUS_PROCESSED STATUS_DOWNLOADING);

sub info {
    my $self = shift;
    $self->render(json => $self->minion->stats);
}

sub status {
    my $self = shift;

    my $data = $self->req->json;
    return $self->render(json => {error => 'No lock specified'}, status => 400) unless my $lock = $data->{lock};

    my $status = $self->progress->downloading($lock) ? STATUS_DOWNLOADING : STATUS_PROCESSED;
    my $res = {status => $status};

    if ($data->{id}) {
        return $self->render(json => {error => 'Specified job ID is invalid'}, status => 404)
          unless my $job = $self->minion->job($data->{id});

        return $self->render(json => {error => 'Job info not available'}, status => 404)
          unless my $job_info = $job->info;

        $res->{result} = $job_info->{result};
        $res->{output} = $job_info->{notes}{output};
    }

    $self->render(json => $res);
}

sub enqueue {
    my $self = shift;

    my $data = $self->req->json;
    return $self->render(json => {error => 'No Task defined'})
      unless defined(my $task = $data->{task});
    return $self->render(json => {error => 'No Arguments defined'})
      unless defined(my $args = $data->{args});
    return $self->render(json => {error => 'No lock defined'})
      unless defined(my $lock = $data->{lock});

    $self->app->log->debug("Requested [$task] Args: @{$args} Lock: $lock");

    return $self->render(json => {status => STATUS_DOWNLOADING}) if $self->progress->downloading($lock);

    $self->progress->enqueue($lock);
    my $id = $self->minion->enqueue($task => $args);
    $self->render(json => {status => STATUS_DOWNLOADING, id => $id});
}

1;
