# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::Controller::Admin::JobGroup;
use strict;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my ($self) = @_;
    my $groups = $self->db->resultset("JobGroups")->search(undef, {order_by => 'name'});

    $self->stash('groups', $groups);
    $self->render('admin/group/index');
}

sub create {
    my ($self) = @_;

    my $ng = $self->db->resultset("JobGroups")->create({name => $self->param('name')});
    if ($ng) {
        $self->flash('info', 'Group '. $ng->name .' created');
    }
    $self->redirect_to(action => 'index');

}

1;
