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

package OpenQA::Controller::API::V1::Worker;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Scheduler ();
use OpenQA::WebSockets qw/ws_create/;
use DBIx::Class::Timestamps qw/now/;
use Try::Tiny;

sub list {
    my ($self) = @_;

    my $workers = $self->db->resultset("Workers");
    my $ret = [];

    while (my $w = $workers->next) {
        next unless ($w->id);
        push(@$ret, $w->info);
    }
    $self->render(json => { workers => $ret });
}

# TODO: this function exists purely for unit tests to be able to register
# workers without fixtures. We need to avoid this
sub _register {
    my ($self, $schema, $host, $instance, $caps) = @_;

    my $worker = $schema->resultset("Workers")->search(
        {
            host => $host,
            instance => int($instance),
        }
    )->first;

    if ($worker) { # worker already known. Update fields and return id
        $worker->update({ t_updated => now() });
    }
    else {
        $worker = $schema->resultset("Workers")->create(
            {
                host => $host,
                instance => $instance
            }
        );
    }
    # store worker's capabilities to database
    $worker->update_caps($caps) if $caps;

    # in case the worker died ...
    # ... restart job assigned to this worker
    if (my $job = $worker->job) {
        $job->set_property('JOBTOKEN');
        OpenQA::Scheduler::job_duplicate(jobid => $job->id);
        # .. set it incomplete
        $job->update(
            {
                state => OpenQA::Schema::Result::Jobs::DONE,
                result => OpenQA::Schema::Result::Jobs::INCOMPLETE,
                worker_id => 0,
            }
        );
    }

    $worker->set_property('INTERACTIVE', 0);
    $worker->set_property('INTERACTIVE_REQUESTED', 0);
    $worker->set_property('STOP_WAITFORNEEDLE', 0);
    $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', 0);

    die "got invalid id" unless $worker->id;
    return $worker->id;
}

sub create {
    my ($self) = @_;

    my $validation = $self->validation;
    my @mandatory_params = (qw/host instance cpu_arch mem_max worker_class/);
    for my $k (@mandatory_params) {
        $validation->required($k);
    }
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (@mandatory_params) {
            $self->app->log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= ' '.$k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $host = $self->param('host');
    my $instance = $self->param('instance');
    my $caps = {};

    $caps->{cpu_modelname} = $self->param('cpu_modelname');
    $caps->{cpu_arch} = $self->param('cpu_arch');
    $caps->{cpu_opmode} = $self->param('cpu_opmode');
    $caps->{mem_max} = $self->param('mem_max');
    $caps->{worker_class} = $self->param('worker_class');

    my $id = $self->_register($self->db, $host, $instance, $caps);
    $self->render(json => { id => $id} );

}

sub show {
    my ($self) = @_;
    my $worker = $self->db->resultset("Workers")->find($self->param('workerid'));
    if ($worker) {
        $self->render(json => {worker => $worker->info });
    }
    else {
        $self->reply->not_found;
    }
}

sub websocket_create {
    my ($self) = @_;
    my $workerid = $self->stash('workerid');
    $self->app->log->debug("Worker $workerid requested websocket connection\n");
    try {
        ws_create($workerid, $self);
    }
    catch {
        $self->render(json => {error => $_}, status => 404);
    };
}

1;
# vim: set sw=4 et:
