# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Appearance;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($self) {
    $self->render;
}

sub save ($self) {
    my $validation = $self->validation;
    $validation->required('theme')->in('light', 'dark', 'detect');
    $validation->optional('seasonal_decorations')->in('auto', 'on', 'off');
    # is_valid would only look at the last validated field
    return $self->reply->exception('Invalid theme settings') if $validation->has_error;

    my $theme = $validation->param('theme');
    $self->session->{theme} = $theme;
    my $seasonal = $validation->param('seasonal_decorations');
    $self->session->{seasonal_decorations} = $seasonal if defined $seasonal;
    $self->flash(info => 'Theme preferences updated');

    $self->redirect_to('appearance');
}

1;
