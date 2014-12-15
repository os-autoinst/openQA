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

package OpenQA::API::V1::Worker;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;
    $self->render(json => { workers => Scheduler::list_workers });
}

sub create {
    my $self = shift;
    my $host = $self->param('host');
    my $instance = $self->param('instance');
    my $backend= $self->param('backend');
    my $caps = {};

    $caps->{cpu_modelname} = $self->param('cpu_modelname');
    $caps->{cpu_arch} = $self->param('cpu_arch');
    $caps->{cpu_opmode} = $self->param('cpu_opmode');
    $caps->{mem_max} = $self->param('mem_max');

    my $res = Scheduler::worker_register($host, $instance, $backend, $caps);
    $self->render(json => { id => $res} );
}

sub show {
    my $self = shift;
    my $res = Scheduler::worker_get($self->stash('workerid'));
    if ($res) {
        $self->render(json => {worker => $res });
    }
    else {
        $self->render_not_found;
    }
}

1;
# vim: set sw=4 et:
