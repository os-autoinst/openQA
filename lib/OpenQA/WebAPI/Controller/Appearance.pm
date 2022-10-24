# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Appearance;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($self) {
    $self->render;
}

sub save ($self) {
    my $validation = $self->validation;
    $validation->required('theme')->in('light', 'dark', 'detect');
    return $self->reply->exception('Invalid theme settings') unless $validation->is_valid;

    my $theme = $validation->param('theme');
    $self->session->{theme} = $theme;
    $self->flash(info => 'Theme preferences updated');

    $self->redirect_to('appearance');
}

1;
