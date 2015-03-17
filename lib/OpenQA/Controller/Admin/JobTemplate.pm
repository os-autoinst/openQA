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

package OpenQA::Controller::Admin::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';
use DateTime::Format::SQLite;

sub index {
    my ($self) = @_;
    $self->validation->required('groupid')->like(qr/^[0-9]+$/);
    $self->stash('group', $self->db->resultset("JobGroups")->find($self->param('groupid')));

    my @machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});
    $self->stash('machines', \@machines);
    my @tests = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});
    $self->stash('tests', \@tests);

    $self->render('admin/job_template/index');
}

1;
