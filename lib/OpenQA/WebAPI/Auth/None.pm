# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::None;
use Mojo::Base -base, -signatures;

use constant DEFAULT_ADMIN => 'admin';

sub auth_setup ($app) {
    my $key_val = $ENV{OPENQA_AUTH_NONE_KEY} // 'DEADBEEFDEADBEEF';
    my $secret_val = $ENV{OPENQA_AUTH_NONE_SECRET} // 'DEADBEEFDEADBEEF';
    my $user = $app->schema->resultset('Users')->create_user(
        DEFAULT_ADMIN,
        fullname => 'Administrator',
        email => 'admin@example.com',
        is_admin => 1,
        is_operator => 1,
    );
    $user->api_keys->update_or_create(
        {
            key => $key_val,
            secret => $secret_val,
            t_expiration => undef,
        });
}

sub auth_login ($self) {
    auth_setup($self->app);
    $self->session->{user} = DEFAULT_ADMIN;
    return (error => 0);
}

1;
