# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::SshKey;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Constants 'API_KEY_COMMENT_MAX_LENGTH';
use OpenQA::SSHKey 'parse_public_key';

sub create ($self) {
    my $validation = $self->validation;
    $validation->required('public_key');
    $validation->required('title')->size(1, API_KEY_COMMENT_MAX_LENGTH);
    my $error;
    if ($validation->has_error) {
        $error = 'A public key and a title are required';
    }
    elsif (my $parsed = parse_public_key($validation->param('public_key'))) {
        if ($self->schema->resultset('SshKeys')->search({fingerprint => $parsed->{fingerprint}})->count) {
            $error = 'This SSH key is already registered';
        }
        else {
            $self->current_user->ssh_keys->create(
                {
                    public_key => $parsed->{public_key},
                    fingerprint => $parsed->{fingerprint},
                    title => $validation->param('title'),
                });
        }
    }
    else {
        $error = 'Invalid SSH public key';
    }
    $self->flash(error => "Error adding the SSH key: $error") if $error;
    $self->redirect_to('api_keys');
}

sub destroy ($self) {
    my $key = $self->current_user->find_related('ssh_keys', {id => $self->param('sshkeyid')});
    if ($key) {
        $key->delete;
        $self->flash(info => 'SSH key deleted');
    }
    else {
        $self->flash(error => 'SSH key not found');
    }
    $self->redirect_to('api_keys');
}

1;
