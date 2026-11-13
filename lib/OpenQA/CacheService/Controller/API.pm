# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Controller::API;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub info ($self) { $self->render(json => $self->minion->stats) }

sub status ($self) {
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
    my $notes = $info->{notes};
    if ($info->{state} eq 'finished' && !$self->progress->is_downloading($notes->{lock})) {
        # Output from the job that actually did the download
        if (my $id = $notes->{downloading_job}) {
            if (my $job = $self->minion->job($id)) {
                if (my $dl_info = $job->info) {
                    return $self->render(json => {error => "Minion job #$id failed: $dl_info->{result}"}, status => 500)
                      if $dl_info->{state} eq 'failed';
                    return $self->render(json => {status => 'downloading'})
                      if $dl_info->{state} ne 'finished';
                    $status = {
                        status => 'processed',
                        result => $info->{result},
                        output => $dl_info->{notes}{output},
                        has_download_error => $dl_info->{notes}{has_download_error}};
                    return $self->render(json => $status);
                }
            }
        }

        $status = {
            status => 'processed',
            result => $info->{result},
            output => $notes->{output},
            has_download_error => $notes->{has_download_error}};
    }

    $self->render(json => $status);
}

# create `cache_tests` jobs with increased prio because many jobs can benefit/proceed if they
# are processed (as the have only a few number of test distributions compared to the number
# different assets)
my %DEFAULT_PRIO_BY_TASK = (cache_tests => 10);

sub enqueue ($self) {
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
    my $attempts = $data->{attempts} // 3;
    my $id
      = $self->minion->enqueue($task => $args => {notes => {lock => $lock}, priority => $prio, attempts => $attempts});
    $self->render(json => {status => 'downloading', id => $id});
}

1;
