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
use OpenQA::IPC;
use OpenQA::Utils;
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
    my ($self) = @_;
    my $live    = !looks_like_number($self->param('live')) ? 0 : !!$self->param('live');
    my $workers = $self->db->resultset("Workers");
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
    my ($self, $schema, $host, $instance, $caps) = @_;

    die "Incompatible websocket api"
      if OpenQA::Constants::WEBSOCKET_API_VERSION() != ($caps->{websocket_api_version} // 0);

    my $worker = $schema->resultset("Workers")->search(
        {
            host     => $host,
            instance => int($instance),
        })->first;

    if ($worker) {    # worker already known. Update fields and return id
        $worker->update({t_updated => now()});
    }
    else {
        $worker = $schema->resultset("Workers")->create(
            {
                host     => $host,
                instance => $instance,
                job_id   => undef
            });
    }
    # store worker's capabilities to database
    $worker->update_caps($caps) if $caps;
    # in case the worker died ...
    # ... restart job assigned to this worker
    if (my $job = $worker->job) {
        $job->set_property('JOBTOKEN');
        $job->auto_duplicate;

        # .. set it incomplete
        $job->update(
            {
                state  => OpenQA::Schema::Result::Jobs::DONE,
                result => OpenQA::Schema::Result::Jobs::INCOMPLETE,
            });
        $worker->update({job_id => undef});
    }

    $worker->set_property('INTERACTIVE',                  0);
    $worker->set_property('STOP_WAITFORNEEDLE',           0);
    $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', 0);

    # $worker->seen();
    die "got invalid id" unless $worker->id;
    return $worker->id;
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
        $id = $self->_register($self->db, $host, $instance, $caps);
    }
    catch {
        if (/Incompatible/) {
            $self->render(status => 426, json => {error => $_});
        }
        else {
            die $_;
        }

    };

    $self->emit_event('openqa_worker_register', {id => $id, host => $host, instance => $instance, caps => $caps});
    $self->render(json => {id => $id});
}

=over 4

=item show()

Prints information from a worker given its ID. Each entry contains the "hostname",
the boolean flag "connected" which can be 0 or 1 depending on the connection to
the websockets server and the field "status" which can be "dead", "idle", "running".
A worker can be considered "up" when "connected=1" and "status!=dead"'

=back

=cut

sub show {
    my ($self) = @_;
    my $worker = $self->db->resultset("Workers")->find($self->param('workerid'));
    if ($worker) {
        $self->render(json => {worker => $worker->info(1)});
    }
    else {
        $self->reply->not_found;
    }
}

1;
# vim: set sw=4 et:
