# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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

package OpenQA::WebAPI::Controller::API::V1::Locks;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::IPC;

sub mutex_action {
    my ($self)     = @_;
    my $name       = $self->stash('name');
    my $jobid      = $self->stash('job_id');
    my $validation = $self->validation;

    $validation->required('action')->in(qw(lock unlock));
    $validation->optional('where')->like(qr/^[0-9]+$/);
    return $self->render(text => 'Bad request', status => 400) if ($validation->has_error);

    my $action = $validation->param('action');
    my $where  = $validation->param('where');
    my $ipc    = OpenQA::IPC->ipc;

    my $res;
    if ($action eq 'lock') {
        $res = $ipc->scheduler('mutex_lock', $name, $jobid, $where);
    }
    else {
        $res = $ipc->scheduler('mutex_unlock', $name, $jobid);
    }
    return $self->render(text => 'ack',  status => 200) if $res > 0;
    return $self->render(text => 'nack', status => 410) if $res < 0;
    return $self->render(text => 'nack', status => 409);
}

sub mutex_create {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');

    my $validation = $self->validation;

    $validation->required('name')->like(qr/^[0-9a-zA-Z_]+$/);
    return $self->render(text => 'Bad request', status => 400) if ($validation->has_error);

    my $name = $validation->param('name');

    my $ipc = OpenQA::IPC->ipc;
    my $res = $ipc->scheduler('mutex_create', $name, $jobid);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

1;
# vim: set sw=4 et:
