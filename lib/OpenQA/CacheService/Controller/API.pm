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

use OpenQA::CacheService::Model::Cache qw(STATUS_PROCESSED STATUS_ENQUEUED STATUS_DOWNLOADING STATUS_ERROR);

sub info {
    my $self = shift;
    $self->render(json => $self->minion->stats);
}

sub status {
    my $self = shift;

    my $data      = $self->req->json;
    my $lock_name = $data->{lock};
    return $self->render(json => {error => 'No lock specified.'}, status => 400) unless $lock_name;

    my $lock = $lock_name;
    my %res  = (
        status => (
            $self->progress->downloading($lock)
            ? STATUS_DOWNLOADING
            : STATUS_PROCESSED
        ));

    if ($data->{id}) {
        my $job = $self->minion->job($data->{id});
        return $self->render(json => {error => 'Specified job ID is invalid.'}, status => 404) unless $job;

        my $job_info = $job->info;
        return $self->render(json => {error => 'Job info not available.'}, status => 404) unless $job_info;
        $res{result} = $job_info->{result};
        $res{output} = $job_info->{notes}->{output};
    }

    $self->render(json => \%res);
}

sub enqueue {
    my $self = shift;

    my $data = $self->req->json;
    my $task = $data->{task};
    my $args = $data->{args};

    return $self->render(json => {status => STATUS_ERROR, error => 'No Task defined'})
      unless defined $task;
    return $self->render(json => {status => STATUS_ERROR, error => 'No Arguments defined'})
      unless defined $args;

    my $lock = $data->{lock} ? $data->{lock} : @$args;
    $self->app->log->debug("Requested [$task] Args: @{$args} Lock: $lock");

    return $self->render(json => {status => STATUS_DOWNLOADING}) if $self->progress->downloading($lock);

    $self->progress->enqueue($lock);
    my $id = $self->minion->enqueue($task => $args);

    $self->render(json => {status => STATUS_ENQUEUED, id => $id});
}

1;
