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
    my ($self) = @_;
    my @users = $self->db->resultset("Users")->search(undef)->all;

    $self->stash('users', \@users);
    $self->render('admin/user/index');
}

sub update {
    my ($self) = @_;
    my $set = $self->db->resultset('Users');
    my $is_admin = 0;
    my $is_operator = 0;
    my $role = $self->param('role') // 'user';

    if ($role eq 'admin') {
        $is_admin = 1;
        $is_operator = 1;
    }
    elsif ($role eq 'operator') {
        $is_operator = 1;
    }

    my $user = $set->find($self->param('userid'));
    if (!$user) {
        $self->flash('error', "Can't find that user");
    }
    else {
        $user->update({is_admin => $is_admin, is_operator => $is_operator});
        $self->flash('info', 'User '. $user->nickname .' updated');
    }

    $self->redirect_to($self->url_for('admin_users'));
}

1;
