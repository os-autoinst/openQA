# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::SshKey;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Feature::Compat::Try;

use DateTime::Format::Pg;
use OpenQA::Constants 'API_KEY_COMMENT_MAX_LENGTH';

sub index ($self) {
    my @pubic_keys = $self->current_user->pubic_keys;
    $self->stash('pubic_keys', \@pubic_keys);
}

sub create ($self) {
    my $user = $self->current_user;
    my $expiration;
    my $validation = $self->validation;
    $validation->optional('t_expiration', 'seconds_optional')->datetime;
    $validation->required('title')->size(1, API_KEY_COMMENT_MAX_LENGTH);
    $validation->required('public_key')->size(1, 1000);

    my $error;
    if ($validation->has_error('title')) { $error = 'Title must not be empty' }
    if ($validation->has_error('public_key')) { $error = 'Public key must not be empty' }
    if (!$error && $validation->is_valid('t_expiration')) {
        try { $expiration = DateTime::Format::Pg->parse_datetime($validation->param('t_expiration')) }
        catch ($e) { $error = $e }    # uncoverable statement
    }

    unless ($error) {
        my $key = $self->schema->resultset('SshKeys')->create(
            {
                user_id => $user->id,
                title => $validation->param('title'),
                public_key => $validation->param('public_key'),
                t_expiration => $expiration,
            });
        $error = 'Invalid public key' unless $key->is_valid_public_key;
        $key->delete if $error;
    }

    if ($error) {
        my $msg = "Error adding the SSH key: $error";
        $self->app->log->debug($msg);
        $self->flash(error => $msg);
    }
    $self->redirect_to(action => 'index');
}

sub destroy ($self) {
    my $user = $self->current_user;
    my $key = $user->find_related('ssh_keys', {id => $self->param('sshkeyid')});

    if ($key) {
        $key->delete;
        $self->flash(info => 'SSH key deleted');
    }
    else {
        $self->flash(error => 'SSH key not found in databse');
    }
    $self->redirect_to($self->url_for('ssh_keys'));
}

1;
