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

package OpenQA::API::V1::Command;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    $self->render(json => {commands => Scheduler::command_get($workerid)});
}

sub create {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    my $command = $self->param('command');

    $self->render(json => {id => Scheduler::command_enqueue_checked(workerid => $workerid, command => $command)});
}

sub destroy {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    my $id = $self->stash('commandid');

    my $res = Scheduler::command_dequeue(workerid => $workerid, id => $id);
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \($res == 1)});
}

1;
# vim: set sw=4 et:
