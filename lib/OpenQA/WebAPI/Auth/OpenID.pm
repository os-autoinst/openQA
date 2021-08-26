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

package OpenQA::WebAPI::Auth::OpenID;
use Mojo::Base -base;

use OpenQA::Log qw(log_error);
use LWP::UserAgent;
use Net::OpenID::Consumer;
use MIME::Base64 qw(encode_base64url decode_base64url);

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

    my $claimed_id = $csr->claimed_identity($self->config->{openid}->{provider});
    if (!defined $claimed_id) {
        log_error("Claiming OpenID identity for URL '$url' failed: " . $csr->err);
        return;
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
            mode             => 'fetch_request',
            required         => 'email,fullname,nickname,firstname,lastname',
            'type.email'     => "http://schema.openid.net/contact/email",
            'type.fullname'  => "http://axschema.org/namePerson",
            'type.nickname'  => "http://axschema.org/namePerson/friendly",
            'type.firstname' => 'http://axschema.org/namePerson/first',
            'type.lastname'  => 'http://axschema.org/namePerson/last',
        },
    );

    my $return_url = Mojo::URL->new(qq{$url/response});
    if ($self->req->headers->referrer) {
        my $return_page = Mojo::URL->new($self->req->headers->referrer)->path_query;
        # return_page is encoded using base64 (in a version that avoids / and + symbol)
        # as any special characters like / or ? when urlencoded via % symbols,
        # result in a naive_verify_failed_return error
        $return_url = $return_url->query({return_page => encode_base64url($return_page)});
    }
    my $check_url = $claimed_id->check_url(
        delayed_return => 1,
        return_to      => $return_url,
        trust_root     => qq{$url/},
    );
    return (redirect => $check_url, error => 0) if $check_url;
    return (error    => $csr->err);
}

sub auth_response {
    my ($self) = @_;

    my %params = @{$self->req->params->pairs};
    my $url    = $self->app->config->{global}->{base_url} || $self->req->url->base;
    return (error => 'Got response on http but https is forced. MOJO_REVERSE_PROXY not set?')
      if ($self->app->config->{openid}->{httpsonly} && $url !~ /^https:\/\//);
    %params = map { $_ => URI::Escape::uri_unescape($params{$_}) } keys %params;

    my $csr = Net::OpenID::Consumer->new(
        debug           => sub { $self->app->log->debug("Net::OpenID::Consumer: " . join(' ', @_)); },
        ua              => LWP::UserAgent->new,
        required_root   => $url,
        consumer_secret => $self->app->config->{_openid_secret},
        args            => \%params,
    );

    my $err_handler = sub {
        my ($err, $txt) = @_;
        $self->app->log->error("$err: $txt");
        $self->flash(error => "$err: $txt");
        return (error => 0);
    };

    $csr->handle_server_response(
        not_openid => sub {
            return $err_handler->("Failed to login", "OpenID provider returned invalid data. Please retry again");
        },
        setup_needed => sub {
            my $setup_url = shift;

            # Redirect the user to $setup_url
            $setup_url = URI::Escape::uri_unescape($setup_url);
            $self->app->log->debug(qq{setup_url[$setup_url]});

            return (redirect => $setup_url, error => 0);
        },
        cancelled => sub { },    # Do something appropriate when the user hits "cancel" at the OP
        verified  => sub {
            my $vident = shift;
            my $sreg   = $vident->signed_extension_fields('http://openid.net/extensions/sreg/1.1');
            my $ax     = $vident->signed_extension_fields('http://openid.net/srv/ax/1.0');

            my $email    = $sreg->{email}    || $ax->{'value.email'}    || 'nobody@example.com';
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
                        $fullname .= ' ' . $ax->{'value.lastname'};
                    }
                }
                else {
                    $fullname = $nickname;
                }
            }

            my $user = $self->schema->resultset('Users')->create_user(
                $vident->{identity},
                email    => $email,
                nickname => $nickname,
                fullname => $fullname
            );
            $self->session->{user} = $vident->{identity};
        },
        error => sub {
            return $err_handler->(@_);
        },
    );

    return (redirect => decode_base64url($csr->args('return_page'), error => 0)) if $csr->args('return_page');
    return (redirect => 'index', error => 0);
}

1;
