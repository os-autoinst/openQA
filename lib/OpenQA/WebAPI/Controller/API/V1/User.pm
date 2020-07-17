# Copyright (C) 2020 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::User;
use Mojo::Base 'Mojolicious::Controller';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::User

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::User;

=head1 DESCRIPTION

Implements User API.

=head1 METHODS

=over 4

=item delete()

Deletes an existing user.

=back

=cut

sub delete {
    my ($self) = @_;
    my $user = $self->schema->resultset('Users')->find($self->param('id'));
    return $self->render(json => {error => 'Not found'}, status => 404) unless $user;
    my $result = $user->delete();
    $self->emit_event('openqa_user_deleted', {username => $user->username});
    $self->render(json => {result => $result});
}

1;
