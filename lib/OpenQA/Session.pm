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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Session;
use Mojo::Base 'Mojolicious::Controller';

use Carp;
use Net::OpenID::Consumer;
use URI::Escape;
use LWP::UserAgent;

sub auth {
    my $self = shift;

    if ($self->is_authorized) {
        return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
        $self->render(text => 'Bad CSRF token!', status => 403);
    } else {
        $self->render(text => "Forbidden", status => 403);
    }
    return undef;
}

sub destroy {
    my $self = shift;

    delete $self->session->{user};
    $self->redirect_to('index');
}

sub create {
    my $self = shift;
    my $url = $self->app->config->{base_url} || $self->req->url->base;

    my $csr = Net::OpenID::Consumer->new(
	ua              => LWP::UserAgent->new,
	required_root   => $url,
	consumer_secret => $self->app->config->{_openid_secret},
	);
    my $claimed_id = $csr->claimed_identity($self->config->{openid}->{provider});
    my $check_url = $claimed_id->check_url(
	return_to  => qq{$url/response},
	trust_root => qq{$url/},
	);

    return $self->redirect_to($check_url);
}

sub response {
    my $self = shift;
    my %params = @{ $self->req->query_params->params };
    my $url = $self->app->config->{base_url} || $self->req->url->base;

    while ( my ( $k, $v ) = each %params ) {
	$params{$k} = URI::Escape::uri_unescape($v);
    }

    my $csr = Net::OpenID::Consumer->new(
        ua              => LWP::UserAgent->new,
        required_root   => $url,
        consumer_secret => $self->app->config->{_openid_secret},
        args            => \%params,
	);

    my $msg = "The openID server doesn't respond";

    $csr->handle_server_response(
        not_openid => sub {
            die "Not an OpenID message";
        },
        setup_required => sub {
            my $setup_url = shift;

            # Redirect the user to $setup_url
            $msg = qq{require setup [$setup_url]};

            $setup_url = URI::Escape::uri_unescape($setup_url);
            $self->app->log->debug(qq{setup_url[$setup_url]});

            $msg = q{};
            return $self->redirect_to($setup_url);
        },
        cancelled => sub {
            # Do something appropriate when the user hits "cancel" at the OP
            $msg = 'cancelled';
        },
        verified => sub {
            my $vident = shift;
            my $id = $vident->{identity};

            my $user = $self->db->resultset("Users")->find_or_create({openid => $id});
            $msg = 'verified';
            $self->session->{user} = $vident->{identity};
        },
        error => sub {
            my $err = shift;
            $self->app->log->error($err);
            croak($err);
        },
	);

    return $self->redirect_to("index");
}

sub test {
    my $self = shift;
    $self->render(text=>"You can see this because you are " . $self->current_user->openid);
}

1;
