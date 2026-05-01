# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::None;
use Mojo::Base -base, -signatures;

use constant DEFAULT_ADMIN => 'admin';

sub auth_setup ($app) {
    $app->schema->resultset('Users')->create_user(
        DEFAULT_ADMIN,
        fullname => 'Administrator',
        email => 'admin@example.com',
        is_admin => 1,
        is_operator => 1,
    );
}

sub auth_login ($self) {
    auth_setup($self->app);
    $self->session->{user} = DEFAULT_ADMIN;
    return (error => 0);
}

sub unauthenticated_user ($self, $app) {
    my $user = $app->schema->resultset('Users')->find({username => DEFAULT_ADMIN});
    if ($user && (!$user->is_admin || !$user->is_operator)) {
        $user->update({is_admin => 1, is_operator => 1});
    }
    return $user;
}

1;
