# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Controller::Session;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Carp 'croak';
use OpenQA::WebAPI::Auth::Local qw(hash_password);

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

sub return_page ($self) { $self->param('return_page') || $self->req->headers->referrer }

sub create ($self) {
    my $ref = $self->param('return_page') || $self->req->headers->referrer;
    my $config = $self->app->config;
    my $auth_method = $config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    return $self->render(text => 'Forbidden via file domain', status => 403)
      if $self->via_domain($config->{global}->{file_domain});

    # prevent redirecting loop when referrer is login page
    if (!$ref || Mojo::URL->new($ref)->path->to_string eq $self->url_for('login')->path->to_string) {
        $ref = 'index';
    }

    croak "Method auth_login missing from class $auth_module" unless my $sub = $auth_module->can('auth_login');

    my %res = $self->$sub;
    return $self->_render_forbidden unless keys %res;
    return $self->_render_forbidden($res{error}) if $res{error};
    return undef if $res{manual};
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

sub register_form ($self) {
    return $self->_render_forbidden unless ($self->app->config->{auth}->{method} // '') eq 'Local';
    return $self->render('main/register');
}

sub register ($self) {
    return $self->_render_forbidden unless ($self->app->config->{auth}->{method} // '') eq 'Local';

    my $username = $self->param('username');
    my $password = $self->param('password');

    return $self->_render_forbidden('Invalid username')
      if !defined $username || $username !~ /^[A-Za-z0-9_.@+-]{3,64}$/;

    return $self->_render_forbidden('Password must be at least 8 characters')
      if !defined $password || length $password < 8;

    return $self->_render_forbidden('Password cannot be whitespace only')
      if $password =~ /^\s*$/;

    return $self->_render_forbidden('Password cannot match username')
      if $username eq $password;

    return $self->_render_forbidden('Username already taken')
      if $self->schema->resultset('Users')->search({username => $username})->count;

    my $user = $self->schema->resultset('Users')->create_user(
        $username,
        provider => 'Local',
        password => hash_password($password),
    );

    $self->schema->resultset('AuditEvents')->create(
        {
            user_id => $user->id,
            event => 'user_register',
            event_data => '{}',
        });

    $self->flash(info => 'Registration successful. Please log in.');
    return $self->redirect_to('login');
}

1;
