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

package OpenQA::API::V1::Job;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;

    my @args;
    for my $arg (qw/state build iso maxage fulldetails/) {
        next unless defined $self->param($arg);
        push @args, $arg;
        push @args, $self->param($arg);
    }

    my $res = Scheduler::list_jobs(@args);
    $self->render(json => {jobs => $res});
}

sub create {
    my $self = shift;
    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;

    my $res = Scheduler::job_create(%up_params);
    $self->render(json => {id => $res});
}

sub grab {
    my $self = shift;

    my $workerid = $self->stash('workerid');
    my $blocking = int($self->param('blocking') || 0);

    my $res = Scheduler::job_grab(workerid => $workerid, blocking => $blocking);
    $self->render(json => {job => $res});
}

sub show {
    my $self = shift;
    my $res = Scheduler::job_get(int($self->stash('jobid')));
    if ($res) {
        $self->render(json => {job => $res});
    }
    else {
        $self->render_not_found;
    }
}

# set_scheduled set_cancel set_waiting and set_continue
sub set_command {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $command = 'job_set_'.$self->stash('command');

    my $res = eval("Scheduler::$command($jobid)");
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \$res});
}

sub destroy {
    my $self = shift;
    my $res = Scheduler::job_delete(int($self->stash('jobid')));
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub prio {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $prio = int($self->param('prio'));

    my $res = Scheduler::job_set_prio(jobid => $jobid, prio => $prio);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub result {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $result = $self->param('result');

    my $res = Scheduler::job_update_result(jobid => $jobid, result => $result);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub done {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $result = $self->param('result');

    print STDERR "jobid $jobid $result\n";

    my $res = Scheduler::job_set_done(jobid => $jobid, result => $result);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub restart {
    my $self = shift;
    my $name = $self->param('name');

    my @res = Scheduler::job_restart($name);
    $self->render(json => {result => \@res});
}

sub cancel {
    my $self = shift;
    my $name = $self->param('name');

    my $res = Scheduler::job_cancel($name);
    $self->render(json => {result => $res});
}

sub duplicate {
    my $self = shift;
    my $jobid = int($self->param('name'));
    my %args = (jobid => $jobid);
    if (defined $self->param('prio')) {
        $args{prio} = int($self->param('prio'));
    }
    if (defined $self->param('dup_type_auto')) {
        $args{dup_type_auto} = 1;
    }

    my $id = Scheduler::job_duplicate(%args);
    $self->render(json => {id => $id});
}

1;
# vim: set sw=4 et:
