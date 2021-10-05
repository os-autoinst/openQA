# Copyright 2019-2021 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Users;

use Mojo::Base -strict, -signatures;
use base 'DBIx::Class::ResultSet';

sub create_user ($self, $id, %attrs) {
    return unless $id;

    $attrs{username} = $id;
    $attrs{provider} //= '';

    my $user = $self->update_or_new(\%attrs);
    return $user if $user->in_storage;
    if (!$self->find({is_admin => 1}, {rows => 1})) {
        $user->is_admin(1);
        $user->is_operator(1);
    }
    $user->insert;
    return $user;
}

1;
