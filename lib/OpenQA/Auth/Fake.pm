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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Auth::Fake;
use OpenQA::Schema::Result::Users;

require Exporter;
our (@ISA, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK = qw/auth_config auth_login auth_logout/;

sub auth_config {
    my ($config) = @_;
    # no config needed
    return;
}

sub auth_logout {
    return;
}

sub auth_login {
    my ($self) = @_;
    my $headers = $self->req->headers;
    my $username = 'Demo';
    my $fullname = 'Demo User';
    my $email = 'demo@user.org';

    my $user = OpenQA::Schema::Result::Users->create_user($username, $self->db, email => $email, nickname => $username, fullname => $fullname);
    unless ($user->is_admin) {
        $user->is_admin(1);
        $user->is_operator(1);
        $user->update({is_admin => 1, is_operator => 1 });
    }
    my $key = $user->api_keys->find_or_create({key => '1234567890ABCDEF', secret => '1234567890ABCDEF'});
    # expire in a day after login
    $key->update({t_expiration => DateTime->from_epoch(epoch => time + 24 * 3600)});
    $self->session->{user} = $username;
    return ( error => 0 );
}

1;
