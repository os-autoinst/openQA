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

package OpenQA::Login;
use Mojo::Base 'Mojolicious::Controller';

use Net::OpenID::Consumer;
use URI::Escape;
use LWP::UserAgent;


sub auth {
    my $self = shift;

    # XXX TODO - Move this into a table in the database
    my %whitelist = (
	'https://www.suse.com/openid/user/ancorgs' => undef,
	'https://www.suse.com/openid/user/aplanas' => undef,
	'https://www.suse.com/openid/user/coolo' => undef,
	'https://www.suse.com/openid/user/cwh' => undef,
	'https://www.suse.com/openid/user/lnussel' => undef,
	);
    return 1 if exists $whitelist{$self->session->{user}};
}

sub login {
    my $self = shift;
    my %params = @{ $self->req->params->params };
    my $url = $self->app->config->{base_url} || $self->req->url->base;

    # Show the form if there is not data
    my $validation = $self->validation;
    return $self->render unless $validation->has_data;

    # Validate the openID URL
    $validation->required('openid')->like(qr/^https?:\/\/.+$/);
    return $self->render if $validation->has_error;

    my $csr = Net::OpenID::Consumer->new(
	ua              => LWP::UserAgent->new,
	required_root   => $url,
	consumer_secret => $self->app->config->{openid_secret},
	);
    my $claimed_id = $csr->claimed_identity($params{openid});
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
        consumer_secret => $self->app->config->{openid_secret},
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

            # Do something with the VerifiedIdentity object $vident
            $msg = 'verified';
	    $self->session->{user} = $vident->{identity};
        },
        error => sub {
            my $err = shift;
            app->log->error($err);
            die($err);
        },
	);

    return $self->redirect_to("index");
}


sub test {
    my $self = shift;
    $self->render(text=>"You can see this because you are " . $self->session->{user});
}
    
1;
