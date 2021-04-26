# Copyright (C) 2015-2021 SUSE LLC
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

package OpenQA::WebAPI::Auth::Fake;
use Mojo::Base -base;
use Time::Seconds;

sub auth_logout {
    return;
}

sub auth_login {
    my ($self) = @_;
    my $headers = $self->req->headers;

    my %users;
    $users{Demo}
      = {fullname => 'Demo User', email => 'demo@user.org', admin => 1, operator => 1, key => '1234567890ABCDEF'};
    $users{nobody}
      = {fullname => 'Nobody', email => 'nobody@example.com', admin => 0, operator => 0, key => '1111111111111111'};
    $users{otherdeveloper} = {
        fullname => 'Other developer',
        email    => 'dev@example.com',
        admin    => 1,
        operator => 1,
        key      => '2222222222222222'
    };

    my $user     = $self->req->param('user') || 'Demo';
    my $userinfo = $users{$user}             || die "No such user";
    $userinfo->{username} = $user;

    $user = $self->schema->resultset('Users')->create_user(
        $userinfo->{username},
        email    => $userinfo->{email},
        nickname => $userinfo->{username},
        fullname => $userinfo->{fullname});
    $user->is_admin($userinfo->{admin});
    $user->is_operator($userinfo->{operator});
    $user->update;

    my $key = $user->api_keys->find_or_create({key => $userinfo->{key}, secret => '1234567890ABCDEF'});
    # expire in a day after login
    $key->update({t_expiration => DateTime->from_epoch(epoch => time + ONE_DAY)});
    $self->session->{user} = $userinfo->{username};
    return (error => 0);
}

1;
