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
    return $self->render(json => {error => "Minion job #$id info not available"}, status => 404)
      unless my $info = $job->info;
    return $self->render(json => {error => "Minion job #$id failed: $info->{result}"}, status => 500)
      if $info->{state} eq 'failed';

    # Our Minion job will finish early if another job is already downloading,
    # so we have to check if the lock has been released yet too
    my $status = {status => 'downloading'};
    if ($info->{state} eq 'finished' && !$self->progress->is_downloading($info->{notes}{lock})) {
        $status = {status => 'processed', result => $info->{result}, output => $info->{notes}{output}};

        # Output from the job that actually did the download
        if (my $id = $info->{notes}{downloading_job}) {
            if (my $job = $self->minion->job($id)) {
                if (my $info = $job->info) {
                    return $self->render(json => {error => "Minion job #$id failed: $info->{result}"}, status => 500)
                      if $info->{state} eq 'failed';
                    $status->{output} = $info->{notes}{output} if $info->{state} eq 'finished';
                }
            }
        }
    }

    $self->render(json => $status);
}

# create `cache_tests` jobs with increased prio because many jobs can benefit/proceed if they
# are processed (as the have only a few number of test distributions compared to the number
# different assets)
my %DEFAULT_PRIO_BY_TASK = (cache_tests => 10);

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

    my $prio = $data->{priority} // ($DEFAULT_PRIO_BY_TASK{$task} // 0);
    my $id   = $self->minion->enqueue($task => $args => {notes => {lock => $lock}, priority => $prio});
    $self->render(json => {status => 'downloading', id => $id});
}

1;
