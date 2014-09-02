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

package OpenQA::Admin::Workers;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use OpenQA::Worker ();

sub index {
    my $self = shift;

    my $workers_amount = 0;
    my @workers_list = ();

    $workers_amount = OpenQA::Worker::workers_amount();
    @workers_list = OpenQA::Worker::workers_list();

    $self->stash(wamount => $workers_amount);
    $self->stash(wlist => \@workers_list);

    $self->render('admin/workers/index');
}

1;
# vim: set sw=4 et:
