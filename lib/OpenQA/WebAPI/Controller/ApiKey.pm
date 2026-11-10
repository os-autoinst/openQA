# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::ApiKey;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Feature::Compat::Try;

use DateTime::Format::Pg;
use OpenQA::Constants 'API_KEY_COMMENT_MAX_LENGTH';

sub index ($self) {
    my @keys = $self->current_user->api_keys;
    $self->stash('keys', \@keys);
}

sub create ($self) {
    my $user = $self->current_user;
    my $expiration;
    my $validation = $self->validation;
    $validation->optional('t_expiration', 'seconds_optional')->datetime;
    $validation->optional('comment')->size(0, API_KEY_COMMENT_MAX_LENGTH);
    $validation->optional('is_operator')->in('0', '1');
    $validation->optional('is_admin')->in('0', '1');
    $validation->optional('role')->in('admin', 'operator', 'user');

    my $error;
    if ($validation->has_error) {
        $error = 'Date must be in format ' . DateTime::Format::Pg->format_datetime(DateTime->now());
    }

    my $role = $validation->is_valid('role') ? $validation->param('role') : undef;
    my ($is_operator, $is_admin, $role_error) = $self->parse_api_key_roles($role, $validation, $user);
    $error //= $role_error;

    if (!$error && (my $perm_error = $self->validate_api_key_role_grant($is_admin, $is_operator, $user))) {
        $error = $perm_error;
    }

    if (!$error && $validation->is_valid('t_expiration')) {
        try { $expiration = DateTime::Format::Pg->parse_datetime($validation->param('t_expiration')) }
        catch ($e) { $error = $e }    # uncoverable statement
    }
    unless ($error) {
        try {
            $self->schema->resultset('ApiKeys')->create(
                {
                    user_id => $user->id,
                    t_expiration => $expiration,
                    comment => $validation->param('comment'),
                    is_operator => $is_operator,
                    is_admin => $is_admin,
                });
        }
        catch ($e) { $error = $e }    # uncoverable statement
    }
    if ($error) {
        my $msg = "Error adding the API key: $error";
        $self->app->log->debug($msg);
        $self->flash(error => $msg);
    }
    $self->redirect_to(action => 'index');
}

sub destroy ($self) {
    my $user = $self->current_user;
    my $key = $user->find_related('api_keys', {id => $self->param('apikeyid')});

    if ($key) {
        $key->delete;
        $self->flash(info => 'API key deleted');
    }
    else {
        $self->flash(error => 'API key not found');
    }
    $self->redirect_to($self->url_for('api_keys'));
}

1;
