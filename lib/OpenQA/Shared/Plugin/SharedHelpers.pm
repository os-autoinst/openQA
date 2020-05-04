# Copyright (C) 2019-2020 SUSE LLC
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

package OpenQA::Shared::Plugin::SharedHelpers;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app) = @_;

    $app->helper(schema => sub { OpenQA::Schema->singleton });

    $app->helper(current_user     => \&_current_user);
    $app->helper(is_operator      => \&_is_operator);
    $app->helper(is_admin         => \&_is_admin);
    $app->helper(is_local_request => \&_is_local_request);
}

sub _current_user {
    my $c = shift;

    # If the value is not in the stash
    my $current_user = $c->stash('current_user');
    unless ($current_user && ($current_user->{no_user} || defined $current_user->{user})) {
        my $id   = $c->session->{user};
        my $user = $id ? $c->schema->resultset("Users")->find({username => $id}) : undef;
        $c->stash(current_user => $current_user = $user ? {user => $user} : {no_user => 1});
    }

    return $current_user && defined $current_user->{user} ? $current_user->{user} : undef;
}

sub _is_operator {
    my $c    = shift;
    my $user = shift || $c->current_user;

    return ($user && $user->is_operator);
}

sub _is_admin {
    my $c    = shift;
    my $user = shift || $c->current_user;

    return ($user && $user->is_admin);
}

sub _is_local_request {
    my $c = shift;

    # IPv4 and IPv6 should be treated the same
    my $address = $c->tx->remote_address;
    return $address eq '127.0.0.1' || $address eq '::1';
}

1;
