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

package OpenQA::Controller::Admin::User;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my $self = shift;
    my @users = $self->db->resultset("Users")->search(undef, {order_by => 'openid'});

    $self->stash('users', \@users);
    $self->render('admin/user/index');
}

sub update {
    my $self = shift;
    my $set = $self->db->resultset('Users');
    my $error;
    my %values;

    # Ensure a proper value. Not very perlish, sorry
    if (defined($self->param('is_admin'))) {
        $values{is_admin} = $self->param('is_admin') ? '1' : '0';
    }
    if (defined($self->param('is_operator'))) {
        $values{is_operator} = $self->param('is_operator') ? '1' : '0';
    }

    eval { $set->search({id => $self->param('userid')})->update_all(\%values)};
    $error = $@;

    if ($error) {
        $self->flash('error', "Error updating the user: $error");
    }
    else {
        $self->flash('info', 'User #'.$self->param('userid').' updated');
    }
    $self->redirect_to($self->url_for('admin_users'));
}

1;
