# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Worker;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use DBIx::Class::Timestamps 'now';
use Try::Tiny;
use Scalar::Util 'looks_like_number';
use OpenQA::Constants 'WEBSOCKET_API_VERSION';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Worker

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Worker;

=head1 DESCRIPTION

Implements API methods relating to OpenQA Workers.

=head1 METHODS

=over 4

=item list()

Returns a list of workers with useful information for each including its ID, the host
where the worker is located, the worker instance, the worker status and the worker's
websocket status.

=back

=cut

sub list {
    my ($self)  = @_;
    my $live    = !looks_like_number($self->param('live')) ? 0 : !!$self->param('live');
    my $workers = $self->schema->resultset("Workers");
    my $ret     = [];

    while (my $w = $workers->next) {
        next unless ($w->id);
        push(@$ret, $w->info($live));
    }
    $self->render(json => {workers => $ret});
}

=over 4

=item _register()

Register a worker instance on the database or update its information if it
was already registered.

B<TODO>: this function exists purely for unit tests to be able to register
workers without fixtures so usage elsewhere should be avoided

B<NOTE>: currently this function is used in create (API entry point)

=back

=cut

sub _register {
    my ($self, $schema, $host, $instance, $caps, $jobs_worker_says_it_works_on) = @_;

    die 'Incompatible websocket API version'
      if WEBSOCKET_API_VERSION != ($caps->{websocket_api_version} // 0);

    my $workers = $schema->resultset('Workers');
    my $worker  = $workers->search(
        {
            host     => $host,
            instance => int($instance),
        })->first;

    # update or create database entry for worker
    if ($worker) {
        $worker->update({t_updated => now()});
    }
    else {
        $worker = $workers->create(
            {
                host     => $host,
                instance => $instance,
                job_id   => undef
            });
    }

    # store worker's capabilities to database
    $worker->update_caps($caps) if $caps;

    # mark the jobs the worker is currently supposed to run as incomplete unless the worker claims
    # to still work on these jobs (which might be the case when the worker hasn't actually crashed but
    # just re-registered due to network issues)
    my %jobs_worker_says_it_works_on = map { ($_ => 1) } @$jobs_worker_says_it_works_on;
    my $worker_id                    = $worker->id;
    try {
        $schema->txn_do(
            sub {
                $worker->update({job_id => undef})
                  if _incomplete_previous_job(\%jobs_worker_says_it_works_on, $worker->job);
                _incomplete_previous_job(\%jobs_worker_says_it_works_on, $_) for $worker->unfinished_jobs->all;
            });
    }
    catch {
        log_warning("Unable to incomplete/duplicate or reschedule jobs abandoned by worker $worker_id: $_");
    };

    return $worker_id;
}

sub _incomplete_previous_job {
    my ($jobs_worker_says_it_works_on, $job) = @_;
    return 0 unless defined $job;

    my $job_id = $job->id;
    return 0 if $jobs_worker_says_it_works_on->{$job_id};
    my $job_state = $job->state;
    return 1 if $job_state eq OpenQA::Jobs::Constants::SCHEDULED;

    # set jobs which were only assigned anyways back to scheduled
    if ($job_state eq OpenQA::Jobs::Constants::ASSIGNED) {
        $job->reschedule_state;
        return 1;
    }

    # mark jobs which were already beyond assigned as incomplete and duplicate it
    $job->set_property('JOBTOKEN');
    if (my $duplicate = $job->auto_duplicate) {
        log_debug("Job $job_id duplicated as " . $duplicate->id);
    }
    $job->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
    return 1;
}


=over 4

=item create()

Initializes and registers a worker.

=back

=cut

sub create {
    my ($self)           = @_;
    my $validation       = $self->validation;
    my @mandatory_params = qw(host instance cpu_arch mem_max worker_class);
    for my $k (@mandatory_params) {
        $validation->required($k);
    }
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (@mandatory_params) {
            $self->app->log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $host     = $self->param('host');
    my $instance = $self->param('instance');
    my $job_ids  = $self->every_param('job_id');
    my $caps     = {};

    $caps->{cpu_modelname}                = $self->param('cpu_modelname');
    $caps->{cpu_arch}                     = $self->param('cpu_arch');
    $caps->{cpu_opmode}                   = $self->param('cpu_opmode');
    $caps->{mem_max}                      = $self->param('mem_max');
    $caps->{worker_class}                 = $self->param('worker_class');
    $caps->{websocket_api_version}        = $self->param('websocket_api_version');
    $caps->{isotovideo_interface_version} = $self->param('isotovideo_interface_version');

    my $id;
    try {
        $id = $self->_register($self->schema, $host, $instance, $caps, $job_ids);
    }
    catch {
        if (/Incompatible/) {
            $self->render(status => 426, json => {error => $_});
        }
        else {
            $self->render(status => 500, json => {error => "Failed: $_"});
        }
        return undef;
    };

    my %event_data = (id => $id, host => $host, instance => $instance, caps => $caps);
    $event_data{job_ids} = $job_ids if @$job_ids;
    $self->emit_event('openqa_worker_register', \%event_data);
    $self->render(json => {id => $id});
}

=over 4

=item show()

Prints information from a worker given its ID. Each entry contains the "hostname"
and the field "status" which can be "dead", "idle", "running" and "broken".
A worker can be considered online when the status is not "dead". Broken means that
the worker is able to connect but there is some setup problem on the worker host
preventing it from taking jobs.

=back

=cut

sub show {
    my ($self) = @_;
    my $worker = $self->schema->resultset("Workers")->find($self->param('workerid'));
    if ($worker) {
        $self->render(json => {worker => $worker->info(1)});
    }
    else {
        $self->reply->not_found;
    }
}

=over 4

=item delete()

Deletes a worker which currently has the status "dead" and no job assigned to it. 
An error is returned if the worker doesn't exist or has a different status.

=back

=cut

sub delete {
    my ($self) = @_;
    my $message;
    my $worker_id = $self->param('worker_id');
    my $worker    = $self->schema->resultset("Workers")->find($worker_id);

    if (!$worker) {
        return $self->render(json => {error => "Worker not found."}, status => 404);
    }
    if ($worker->status ne 'dead' || $worker->unfinished_jobs->count) {
        $message = "Worker " . $worker->name . " status is not offline.";
        return $self->render(json => {error => $message}, status => 400);
    }

    eval { $worker->delete };
    if ($@) {
        return $self->render(json => {error => $@}, status => 409);
    }
    $message = "Delete worker " . $worker->name . " successfully.";
    $self->emit_event('openqa_worker_delete', {id => $worker->id, name => $worker->name});
    $self->render(json => {message => $message});
}

1;
