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

package OpenQA::Admin::Machine;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my $self = shift;
    my @machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});

    $self->stash('error', undef);
    $self->stash('machines', \@machines);
    $self->render('admin/machine/index');
}

sub create {
    my $self = shift;
    my $error;
    my $validation = $self->validation;
    $validation->required('name');
    $validation->required('backend');
    $validation->required('variables')->like(qr/^(\w+=[ \,\.\-\w]+;?)+$/);
    if ($validation->has_error) {
        $error = "wrong parameters.";
        if ($validation->has_error('variables')) {
            $error = $error.' Variables should contain a list of assignations delimited by semicolons.';
        }
    }
    else {
        eval { $self->db->resultset("Machines")->create({name => $self->param('name'),backend => $self->param('backend'),variables => $self->param('variables')}) };
        $error = $@;
    }

    if ($error) {
        my @machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});
        $self->stash('error', "Error adding the machine: $error");
        $self->stash('machines', \@machines);
        $self->render('admin/machine/index');
    }
    else {
        $self->flash(info => 'Machine '.$self->param('name').' added');
        $self->redirect_to($self->url_for('admin_machines'));
    }
}

sub add_variable {
    my $self = shift;
    $self->SUPER::add_variable('machine', 'MachineSettings');
}

sub remove_variable {
    my $self = shift;
    $self->SUPER::remove_variable('machine', 'MachineSettings');
}

sub destroy {
    my $self = shift;
    my $machines = $self->db->resultset('Machines');

    if ($machines->search({id => $self->param('machine_id')})->delete_all) {
        $self->flash(info => 'Machine deleted');
    }
    else {
        $self->flash(error => 'Failed to delete machine');
    }
    $self->redirect_to($self->url_for('admin_machines'));
}

1;
