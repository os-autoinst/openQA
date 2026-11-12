# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::SshKey;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Constants 'API_KEY_COMMENT_MAX_LENGTH';

my %ERROR_MESSAGE = (duplicate => 'This SSH key is already registered', invalid => 'Invalid SSH public key');

sub create ($self) {
    my $validation = $self->validation;
    $validation->required('public_key');
    $validation->required('title')->size(1, API_KEY_COMMENT_MAX_LENGTH);
    my $error = $validation->has_error ? 'A public key and a title are required' : undef;
    if (!$error) {
        my (undef, $reason)
          = $self->current_user->add_ssh_key($validation->param('public_key'), $validation->param('title'));
        $error = $ERROR_MESSAGE{$reason} if $reason;
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
