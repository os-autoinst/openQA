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

package OpenQA::Controller::Session;
use Mojo::Base 'Mojolicious::Controller';

use Carp;
use Net::OpenID::Consumer;
use URI::Escape;
use LWP::UserAgent;
use OpenQA::Schema::Result::Users;

sub ensure_operator {
    my $self = shift;

    if ($self->is_operator) {
        return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
        $self->render(text => 'Bad CSRF token!', status => 403);
    }
    else {
        $self->render(text => "Forbidden", status => 403);
    }
    return undef;
}

sub ensure_admin {
    my $self = shift;

    if ($self->is_admin) {
        return 1 if $self->req->method eq 'GET' || $self->valid_csrf;
        $self->render(text => 'Bad CSRF token!', status => 403);
    }
    else {
        $self->render(text => "Forbidden", status => 403);
    }
    return undef;
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
    my $self = shift;

    delete $self->session->{user};
    $self->redirect_to('index');
}

sub create {
    my $self = shift;
    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base->to_string;

    # force secure connection after login
    $url =~ s,^http://,https://, if $self->app->config->{openid}->{httpsonly};

    my $csr = Net::OpenID::Consumer->new(
        ua              => LWP::UserAgent->new,
        required_root   => $url,
        consumer_secret => $self->app->config->{_openid_secret},
    );
    my $claimed_id = $csr->claimed_identity($self->config->{openid}->{provider});
    unless ($claimed_id) {
        # XXX: looks ulgy
        return $self->render(text => $csr->err, status => 500);
    }
    $claimed_id->set_extension_args(
        'http://openid.net/extensions/sreg/1.1',
        {
            required => 'email',
            optional => 'fullname,nickname',
        },
    );
    $claimed_id->set_extension_args(
        'http://openid.net/srv/ax/1.0',
        {
            mode => 'fetch_request',
            'required' => 'email,fullname,nickname,firstname,lastname',
            'type.email' => "http://schema.openid.net/contact/email",
            'type.fullname' => "http://axschema.org/namePerson",
            'type.nickname' => "http://axschema.org/namePerson/friendly",
            'type.firstname' => 'http://axschema.org/namePerson/first',
            'type.lastname' => 'http://axschema.org/namePerson/last',
        },
    );

    my $check_url = $claimed_id->check_url(
        delayed_return => 1,
        return_to  => qq{$url/response},
        trust_root => qq{$url/},
    );

    return $self->redirect_to($check_url);
}

sub response {
    my $self = shift;
    my %params = @{ $self->req->query_params->params };
    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base;

    if ($self->app->config->{openid}->{httpsonly} && $url !~ /^https:\/\//) {
        return $self->render(text => "got response on http but https is forced. MOJO_REVERSE_PROXY not set?", status => 500);
    }

    while ( my ( $k, $v ) = each %params ) {
        $params{$k} = URI::Escape::uri_unescape($v);
    }

    my $csr = Net::OpenID::Consumer->new(
        debug           => sub { $self->app->log->debug("Net::OpenID::Consumer: ".join(' ', @_)); },
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
        setup_needed => sub {
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
            my $sreg = $vident->signed_extension_fields('http://openid.net/extensions/sreg/1.1');
            my $ax = $vident->signed_extension_fields('http://openid.net/srv/ax/1.0');

            my $email = $sreg->{email} || $ax->{'value.email'} || 'nobody@example.com';
            my $nickname = $sreg->{nickname} || $ax->{'value.nickname'} || $ax->{'value.firstname'};
            unless ($nickname) {
                my @a = split(/@/, $email);
                $nickname = $a[0];
            }
            my $fullname = $sreg->{fullname} || $ax->{'value.fullname'};
            unless ($fullname) {
                if ($ax->{'value.firstname'}) {
                    $fullname = $ax->{'value.firstname'};
                    if ($ax->{'value.lastname'}) {
                        $fullname .= ' '.$ax->{'value.lastname'};
                    }
                }
                else {
                    $fullname = $nickname;
                }
            }

            my $user = OpenQA::Schema::Result::Users->create_user($id, $self->db, email => $email, nickname => $nickname, fullname => $fullname);

            $msg = 'verified';
            $self->session->{user} = $id;
        },
        error => sub {
            my ($err, $txt) = @_;
            $self->app->log->error($err, $txt);
            $self->flash(error => "$err: $txt");
            return $self->redirect_to("index");
        },
    );

    return $self->redirect_to("index");
}

sub test {
    my $self = shift;
    $self->render(text=>"You can see this because you are " . $self->current_user->openid);
}

1;
