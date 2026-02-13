# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Controller::Session;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Carp 'croak';

sub _redirect_back ($self) {
    $self->redirect_to($self->url_for('login')->query(return_page => $self->req->url));
    return undef;
}

sub _check_csrf_token ($self) {
    return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
    $self->render(text => 'Bad CSRF token!', status => 403);
    return undef;
}

sub _render_forbidden ($self, $text = 'Forbidden') {
    $self->render(text => $text, status => 403);
    return undef;
}

sub ensure_user ($self) { $self->current_user ? 1 : $self->_redirect_back }

sub ensure_operator ($self) {
    return $self->_redirect_back unless $self->current_user;
    return $self->_render_forbidden unless $self->is_operator;
    return $self->_check_csrf_token;
}

sub ensure_admin ($self) {
    unless ($self->current_user) {
        if (($self->tx->req->headers->accept // '') eq 'application/json') {
            $self->render(json => {'error' => 'No valid user session'}, status => 401);
        }
        else {
            $self->_redirect_back;
        }
        return undef;
    }
    return $self->_render_forbidden unless $self->is_admin;
    return $self->_check_csrf_token;
}

sub destroy ($self) {
    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    if (my $sub = $auth_module->can('auth_logout')) { $self->$sub }
    delete $self->session->{user};
    $self->redirect_to('index');
}

sub _redirect_to_referrer ($self, $ref, $res) {
    if (my $redirect = $res->{redirect}) {
        $self->flash(ref => $self->req->headers->referrer);
        return $self->redirect_to($redirect);
    }
    $self->emit_event('openqa_user_login');
    return $self->redirect_to($ref);
}

sub create ($self) {
    my $ref = $self->req->headers->referrer;
    my $config = $self->app->config;
    my $auth_method = $config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    return $self->render(text => 'Forbidden via file domain', status => 403)
      if $self->via_domain($config->{global}->{file_domain});

    # prevent redirecting loop when referrer is login page
    $ref = 'index' if !$ref or $ref eq $self->url_for('login');

    croak "Method auth_login missing from class $auth_module" unless my $sub = $auth_module->can('auth_login');

    my %res = $self->$sub;
    return $self->_render_forbidden unless keys %res;
    return $self->_render_forbidden($res{error}) if $res{error};
    return if $res{manual};
    return $self->_redirect_to_referrer($ref, \%res);
}

sub response ($self) {
    my $ref = $self->flash('ref');
    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    croak "Method auth_response missing from class $auth_module" unless my $sub = $auth_module->can('auth_response');

    my %res = $self->$sub;
    return $self->_render_forbidden unless keys %res;
    return $self->_render_forbidden($res{error}) if $res{error};
    return $self->_redirect_to_referrer($ref, \%res);
}

sub test ($self) { $self->render(text => 'You can see this because you are ' . $self->current_user->username) }

1;
