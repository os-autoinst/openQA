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

package OpenQA::Auth::OpenID;
use OpenQA::Schema::Result::Users;

use LWP::UserAgent;
use Net::OpenID::Consumer;

require Exporter;
our (@ISA, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK = qw/auth_config auth_login auth_response/;

sub auth_config {
    my ($config) = @_;
    # no config needed
    return;
}

sub auth_login {
    my ($self) = @_;
    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base->to_string;

    # force secure connection after login
    $url =~ s,^http://,https://, if $self->app->config->{openid}->{httpsonly};

    my $csr = Net::OpenID::Consumer->new(
        ua              => LWP::UserAgent->new,
        required_root   => $url,
        consumer_secret => $self->app->config->{_openid_secret},
    );

    my ($claimed_id, $check_url);
    $claimed_id = $csr->claimed_identity($self->config->{openid}->{provider});
    return unless ($claimed_id);
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

    $check_url = $claimed_id->check_url(
        delayed_return => 1,
        return_to  => qq{$url/response},
        trust_root => qq{$url/},
    );

    if ($check_url) {
        return ( redirect => $check_url, error => 0 );
    }
    return ( error => $csr->err );
}

sub auth_response {
    my ($self) = @_;

    # FIXME: Mojo6 hack, remove after version bump
    my %params;
    if ($self->req->query_params->can('params')) {
        %params = @{ $self->req->query_params->params };
    }
    else {
        %params = @{ $self->req->query_params->pairs };
    }

    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base;

    if ($self->app->config->{openid}->{httpsonly} && $url !~ /^https:\/\//) {
        return ( error => 'Got response on http but https is forced. MOJO_REVERSE_PROXY not set?' );
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
            return ( redirect => $setup_url, error => 0 );
        },
        cancelled => sub {
            # Do something appropriate when the user hits "cancel" at the OP
            $msg = 'cancelled';
        },
        verified => sub {
            my $vident = shift;
            my $sreg = $vident->signed_extension_fields('http://openid.net/extensions/sreg/1.1');
            my $ax = $vident->signed_extension_fields('http://openid.net/srv/ax/1.0');

            my $email = $sreg->{email} || $ax->{'value.email'} || 'nobody@example.com';
            my $nickname = $sreg->{nickname} || $ax->{'value.nickname'} || $ax->{'value.firstname'};
            unless ($nickname) {
                my @a = split(/\/([^\/]+)$/, $vident->{identity});
                $nickname = $a[1];
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

            my $user = OpenQA::Schema::Result::Users->create_user($vident->{identity}, $self->db, email => $email, nickname => $nickname, fullname => $fullname);

            $msg = 'verified';
            $self->session->{user} = $vident->{identity};
        },
        error => sub {
            my ($err, $txt) = @_;
            $self->app->log->error($err, $txt);
            $self->flash(error => "$err: $txt");
            return ( error => 0 );
        },
    );

    return ( error => 0 );
}

1;
