# Copyright (C) 2014-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Shared::Controller::Session;
use Mojo::Base 'Mojolicious::Controller';

use Carp 'croak';

sub ensure_user {
    my ($self) = @_;
    return 1 if $self->current_user;
    $self->redirect_to('login');
    return undef;
}

sub ensure_operator {
    my ($self) = @_;
    $self->redirect_to('login')                       and return undef unless $self->current_user;
    $self->render(text => "Forbidden", status => 403) and return undef unless $self->is_operator;
    return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
    $self->render(text => 'Bad CSRF token!', status => 403);
    return undef;
}

sub ensure_admin {
    my ($self) = @_;
    $self->redirect_to('login')                       and return undef unless $self->current_user;
    $self->render(text => "Forbidden", status => 403) and return undef unless $self->is_admin;
    return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
    $self->render(text => 'Bad CSRF token!', status => 403);
    return undef;
}

sub destroy {
    my ($self) = @_;

    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    if (my $sub = $auth_module->can('auth_logout')) { $self->$sub }
    delete $self->session->{user};
    $self->redirect_to('index');
}

sub create {
    my ($self)      = @_;
    my $ref         = $self->req->headers->referrer;
    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";

    # prevent redirecting loop when referrer is login page
    $ref = 'index' if !$ref or $ref eq $self->url_for('login');

    croak "Method auth_login missing from class $auth_module" unless my $sub = $auth_module->can('auth_login');
    my %res = $self->$sub;

    return $self->render(text => 'Forbidden', status => 403) unless %res;
    return $self->render(text => $res{error}, status => 403) if $res{error};
    return if $res{manual};
    if ($res{redirect}) {
        $self->flash(ref => $ref);
        return $self->redirect_to($res{redirect});
    }
    $self->emit_event('openqa_user_login');
    return $self->redirect_to($ref);
}

sub response {
    my ($self)      = @_;
    my $ref         = $self->flash('ref');
    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";

    croak "Method auth_response missing from class $auth_module" unless my $sub = $auth_module->can('auth_response');
    my %res = $self->$sub;

    return $self->render(text => 'Forbidden', status => 403) unless %res;
    return $self->render(text => $res{error}, status => 403) if $res{error};
    if ($res{redirect}) {
        $self->flash(ref => $ref);
        return $self->redirect_to($res{redirect});
    }
    $self->emit_event('openqa_user_login');
    return $self->redirect_to($ref);
}

sub test {
    my $self = shift;
    $self->render(text => "You can see this because you are " . $self->current_user->username);
}

1;
