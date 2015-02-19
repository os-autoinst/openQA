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

package OpenQA::Controller::API::V1::Locks;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Locks;

sub mutex_lock {
    my ($self) = @_;
    my $name = $self->stash('name');
    my $jobid = $self->stash('job_id');
    my $res = OpenQA::Locks::lock($name, $jobid);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

sub mutex_unlock {
    my ($self) = @_;
    my $name = $self->stash('name');
    my $jobid = $self->stash('job_id');
    my $res = OpenQA::Locks::unlock($name, $jobid);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

sub mutex_create {
    my ($self) = @_;
    my $name = $self->stash('name');
    my $jobid = $self->stash('job_id');
    my $res = OpenQA::Locks::create($name, $jobid);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

1;
# vim: set sw=4 et:
