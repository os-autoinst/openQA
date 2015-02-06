# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Controller::Session;
use Mojo::Base 'Mojolicious::Controller';

use Carp;
use Net::OpenID::Consumer;
use URI::Escape;
use LWP::UserAgent;
use OpenQA::Schema::Result::Users;

sub ensure_operator {
    my ($self) = @_;

    if ($self->current_user) {
        if ($self->is_operator) {
            return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
            $self->render(text => 'Bad CSRF token!', status => 403);
        }
        else {
            $self->render(text => "Forbidden", status => 403);
        }
    }
    else {
        $self->redirect_to('login');
    }
    return;
}

sub ensure_admin {
    my ($self) = @_;

    if ($self->current_user) {
        if ($self->is_admin) {
            return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
            $self->render(text => 'Bad CSRF token!', status => 403);
        }
        else {
            $self->render(text => "Forbidden", status => 403);
        }
    }
    else {
        $self->redirect_to('login');
    }
    return;
}

sub ensure_authorized_ip {
    my $self = shift;

    my $addr = $self->tx->remote_address;
    my @auth_ips;
    if ($self->app->config->{'global'}->{'allowed_hosts'}) {
        @auth_ips = split(/ /, $self->app->config->{'global'}->{'allowed_hosts'});
    }
    else {
        @auth_ips = ('127.0.0.1', '::1');
    }
    foreach (@auth_ips) {
        if ($addr =~ /$_/) {
            return 1;
        }
    }
    $self->render(text => "Forbidden", status => 403);
    return undef;
}

sub destroy {
    my ($self) = @_;

    my $auth_method = $self->app->config->{'auth'}->{'method'};
    my $auth_module = "OpenQA::Auth::$auth_method";
    eval {$auth_module->import('auth_logout');};
    if (!$@) {
        auth_logout($self);
    }

    delete $self->session->{user};
    $self->redirect_to('index');
}

sub create {
    my ($self) = @_;
    my $auth_method = $self->app->config->{'auth'}->{'method'};
    my $auth_module = "OpenQA::Auth::$auth_method";
    $auth_module->import('auth_login');

    my %res = auth_login($self);
    if (%res) {
        if ($res{'redirect'}) {
            return $self->redirect_to($res{'redirect'});
        }
        elsif ($res{'error'}) {
            return $self->render(text => $res{'error'}, status => 403);
        }
        return $self->redirect_to('index');
    }
    return $self->render(text => 'Forbidden', status => 403);
}

sub response {
    my ($self) = @_;
    my $auth_method = $self->app->config->{'auth'}->{'method'};
    my $auth_module = "OpenQA::Auth::$auth_method";
    $auth_module->import('auth_response');

    my %res = auth_response($self);
    if (%res) {
        if ($res{'redirect'}) {
            return $self->redirect_to($res{'redirect'});
        }
        elsif ($res{'error'}) {
            return $self->render(text => $res{'error'}, status => 403);
        }
        return $self->redirect_to('index');
    }
    return $self->render(text => 'Forbidden', status => 403);
}

sub test {
    my $self = shift;
    $self->render(text=>"You can see this because you are " . $self->current_user->username);
}

1;
