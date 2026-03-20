# Copyright 2019-2021 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Users;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

sub create_user ($self, $id, %attrs) {
    return unless $id;

    $attrs{username} = $id;
    $attrs{provider} //= '';

    my $existing_user = $self->find({username => $id});
    if ($existing_user && $existing_user->provider ne $attrs{provider}) {
        die "Auth provider mismatch: Account '$id' is registered via '"
          . ($existing_user->provider || 'default')
          . "', but login attempted via '$attrs{provider}'. Admin migration required.\n";
    }

    my $user = $self->update_or_new(\%attrs);
    return $user if $user->in_storage;
    if (!$self->find({is_admin => 1}, {rows => 1})) {
        $user->is_admin(1);
        $user->is_operator(1);
    }
    $user->insert;
    return $user;
}

sub system ($self, $attrs = undef) { $self->find({username => 'system', provider => ''}, $attrs) }

1;
