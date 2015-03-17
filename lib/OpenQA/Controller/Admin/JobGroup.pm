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

sub connect {
    my ($self) = @_;

    $self->validation->required('groupid')->like(qr/^[0-9]+$/);
    $self->stash('group', $self->db->resultset("JobGroups")->find($self->param('groupid')));

    my $products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});
    $self->stash('products', $products);
    my $tests = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});
    $self->stash('tests', $tests);
    my $machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});
    $self->stash('machines', $machines);

    $self->render('admin/group/connect');
}

sub save_connect {
    my ($self) = @_;

    $self->validation->required('groupid')->like(qr/^[0-9]+$/);
    my $group = $self->db->resultset("JobGroups")->find($self->param('groupid'));

    my $values = {
        prio => $self->param('prio')//50,
        product_id => $self->param('medium'),
        machine_id => $self->param('machine'),
        group_id => $group->id,
        test_suite_id => $self->param('test')
    };
    eval { $self->db->resultset("JobTemplates")->create($values)->id };
    if ($@) {
        $self->flash(error => $@);
        $self->redirect_to('job_group_new_media', groupid => $group->id);
    }
    else {
        $self->redirect_to('admin_job_templates', groupid => $group->id);
    }
}

1;
