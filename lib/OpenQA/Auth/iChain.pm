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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Auth::iChain;
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
    my $username = $headers->header('HTTP_X_USERNAME');
    my $email = $headers->header('HTTP_X_EMAIL');
    my $fullname = sprintf('%s %s', $headers->header('HTTP_X_FISTNAME'), $headers->header('HTTP_X_LASTNAME'));

    if ($username) {
        # iChain login
        OpenQA::Schema::Result::Users->create_user($username, $self->db, email => $email, nickname => $username, fullname => $fullname);
        $self->session->{user} = $username;
        return (error => 0);
    }
    return;
}

1;
