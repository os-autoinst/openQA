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

package OpenQA::WebAPI::Controller::Session;
use Mojo::Base 'Mojolicious::Controller';


sub ensure_user {
    my ($self) = @_;
    return 1 if $self->current_user;
    $self->redirect_to('login');
    return undef;
}

sub ensure_operator {
    my ($self) = @_;
    $self->redirect_to('login') and return undef unless $self->current_user;
    $self->render(text => "Forbidden", status => 403) and return undef unless $self->is_operator;
    return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
    $self->render(text => 'Bad CSRF token!', status => 403);
    return undef;
}

sub ensure_admin {
    my ($self) = @_;
    $self->redirect_to('login') and return undef unless $self->current_user;
    $self->render(text => "Forbidden", status => 403) and return undef unless $self->is_admin;
    return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
    $self->render(text => 'Bad CSRF token!', status => 403);
    return undef;
}

sub destroy {
    my ($self) = @_;

    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    eval { $auth_module->import('auth_logout'); };
    auth_logout($self) unless $@;
    delete $self->session->{user};
    $self->redirect_to('index');
}

sub create {
    my ($self)      = @_;
    my $ref         = $self->req->headers->referrer;
    my $auth_method = $self->app->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    $auth_module->import('auth_login');

    # prevent redirecting loop when referrer is login page
    $ref = 'index' if !$ref or $ref eq $self->url_for('login');

    my %res = auth_login($self);
    return $self->render(text => 'Forbidden', status => 403) unless %res;
    return $self->render(text => $res{error}, status => 403) if $res{error};
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
    $auth_module->import('auth_response');

    my %res = auth_response($self);
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
