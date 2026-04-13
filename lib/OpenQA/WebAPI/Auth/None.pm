# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::None;
use Mojo::Base -base, -signatures;

sub auth_setup ($app) {
    my $key_val = $ENV{OPENQA_AUTH_NONE_KEY} // 'DEADBEEFDEADBEEF';
    my $secret_val = $ENV{OPENQA_AUTH_NONE_SECRET} // 'DEADBEEFDEADBEEF';
    my $user = $app->schema->resultset('Users')->create_user(
        'admin',
        fullname => 'Administrator',
        email => 'admin@example.com'
    );
    $user->update({is_admin => 1, is_operator => 1});
    my $key = $user->api_keys->find_or_create({key => $key_val, secret => $secret_val});
    $key->update({t_expiration => undef});
}

sub auth_login ($self) {
    auth_setup($self->app);
    $self->session->{user} = 'admin';
    return (error => 0);
}

1;
