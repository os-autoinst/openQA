# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Appearance;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Time::Seconds;

sub index ($self) {
    $self->render;
}

sub save ($self) {
    my $validation = $self->validation;
    $validation->required('theme')->in('light', 'dark', 'detect');
    $validation->optional('seasonal_decorations')->in('auto', 'on', 'off');
    # is_valid would only look at the last validated field
    return $self->reply->exception('Invalid theme settings') if $validation->has_error;

    # kept in long-lived cookies so the preferences outlive the login session
    my %options = (max_age => 365 * ONE_DAY, path => '/', samesite => 'Lax', secure => $self->req->is_secure);
    $self->cookie(theme => $validation->param('theme'), {%options});
    my $seasonal = $validation->param('seasonal_decorations');
    $self->cookie(seasonal_decorations => $seasonal, {%options}) if defined $seasonal;
    $self->flash(info => 'Theme preferences updated');

    $self->redirect_to('appearance');
}

1;
