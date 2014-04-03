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

package OpenQA::Admin::TestSuite;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my $self = shift;
    my @suites = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});

    $self->stash('error', undef);
    $self->stash('suites', \@suites);
    $self->render('admin/test_suite/index');
}

sub create {
    my $self = shift;
    my $error;
    my $validation = $self->validation;
    $validation->required('name');
    $validation->required('prio')->like(qr/^[0-9]{1,2}$/);
    $validation->required('variables')->like(qr/^(\w+=[ \,\.\-\w]+;?)+$/);
    if ($validation->has_error) {
        $error = "wrong parameters.";
        if ($validation->has_error('variables')) {
            $error = $error.' Variables should contain a list of assignations delimited by semicolons.';
        }
    }
    else {
        eval { $self->db->resultset("TestSuites")->create({name => $self->param('name'),prio => $self->param('prio'),variables => $self->param('variables')}) };
        $error = $@;
    }

    if ($error) {
        my @suites = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});
        $self->stash('error', "Error adding the machine: $error");
        $self->stash('suites', \@suites);
        $self->render('admin/test_suite/index');
    }
    else {
        $self->flash(info => 'Test suite '.$self->param('name').' added');
        $self->redirect_to($self->url_for('admin_test_suites'));
    }
}

sub destroy {
    my $self = shift;
    my $suites = $self->db->resultset('TestSuites');

    if ($suites->search({id => $self->param('testsuiteid')})->delete_all) {
        $self->flash(info => 'Test suite deleted');
    }
    else {
        $self->flash(error => 'Failed to delete test suite');
    }
    $self->redirect_to($self->url_for('admin_test_suites'));
}

1;
