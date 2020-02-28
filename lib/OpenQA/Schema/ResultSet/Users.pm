# Copyright (C) 2019 LLC
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

package OpenQA::Schema::ResultSet::Users;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

sub create_user {
    my ($self, $id, %attrs) = @_;

    return unless $id;
    my $user = $self->update_or_new({username => $id, %attrs});

    if (!$user->in_storage) {
        if (not $self->find({is_admin => 1}, {rows => 1})) {
            $user->is_admin(1);
            $user->is_operator(1);
        }
        $user->insert;
    }
    return $user;
}

1;
