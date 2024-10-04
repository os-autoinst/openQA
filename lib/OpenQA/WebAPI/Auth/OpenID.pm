# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::OpenID;
use Mojo::Base -base, -signatures;

use OpenQA::Log qw(log_error);
use LWP::UserAgent;
use Net::OpenID::Consumer;
use MIME::Base64 qw(encode_base64url decode_base64url);

sub auth_login ($c) {
    my $url = $c->app->config->{global}->{base_url} || $c->req->url->base->to_string;

    # force secure connection after login
    $url =~ s,^http://,https://, if $c->app->config->{openid}->{httpsonly};

    my $csr = Net::OpenID::Consumer->new(
        ua => LWP::UserAgent->new,
        required_root => $url,
        consumer_secret => $c->app->config->{_openid_secret},
    );

    my $claimed_id = $csr->claimed_identity($c->config->{openid}->{provider});
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
            mode => 'fetch_request',
            required => 'email,fullname,nickname,firstname,lastname',
            'type.email' => 'http://schema.openid.net/contact/email',
            'type.fullname' => 'http://axschema.org/namePerson',
            'type.nickname' => 'http://axschema.org/namePerson/friendly',
            'type.firstname' => 'http://axschema.org/namePerson/first',
            'type.lastname' => 'http://axschema.org/namePerson/last',
        },
    );

    my $return_url = Mojo::URL->new(qq{$url/response});
    if (my $return_page = $c->param('return_page') || $c->req->headers->referrer) {
        $return_page = Mojo::URL->new($return_page)->path_query;
        # return_page is encoded using base64 (in a version that avoids / and + symbol)
        # as any special characters like / or ? when urlencoded via % symbols,
        # result in a naive_verify_failed_return error
        $return_url = $return_url->query({return_page => encode_base64url($return_page)});
    }
    my $check_url = $claimed_id->check_url(
        delayed_return => 1,
        return_to => $return_url,
        trust_root => qq{$url/},
    );
    return (redirect => $check_url, error => 0) if $check_url;
    return (error => $csr->err);
}

sub _first_last_name ($ax) { join(' ', $ax->{'value.firstname'} // '', $ax->{'value.lastname'} // '') }

sub _create_user ($c, $id, $email, $nickname, $fullname) {
    $c->schema->resultset('Users')->create_user($id, email => $email, nickname => $nickname, fullname => $fullname);
}

sub _handle_verified ($c, $vident) {
    my $sreg = $vident->signed_extension_fields('http://openid.net/extensions/sreg/1.1');
    my $ax = $vident->signed_extension_fields('http://openid.net/srv/ax/1.0');

    my $email = $sreg->{email} || $ax->{'value.email'} || 'nobody@example.com';
    my $nickname = $sreg->{nickname} || $ax->{'value.nickname'} || $ax->{'value.firstname'};
    unless ($nickname) {
        my @a = split(/\/([^\/]+)$/, $vident->{identity});
        $nickname = $a[1];
    }

    my $fullname = $sreg->{fullname} || $ax->{'value.fullname'} || _first_last_name($ax) || $nickname;

    _create_user($c, $vident->{identity}, $email, $nickname, $fullname);
    $c->session->{user} = $vident->{identity};
}

sub auth_response ($c) {
    my %params = @{$c->req->params->pairs};
    my $url = $c->app->config->{global}->{base_url} || $c->req->url->base;
    return (error => 'Got response on http but https is forced. MOJO_REVERSE_PROXY not set?')
      if ($c->app->config->{openid}->{httpsonly} && $url !~ /^https:\/\//);
    %params = map { $_ => URI::Escape::uri_unescape($params{$_}) } keys %params;

    my $csr = Net::OpenID::Consumer->new(
        debug => sub (@args) { $c->app->log->debug('Net::OpenID::Consumer: ' . join(' ', @args)) },
        ua => LWP::UserAgent->new,
        required_root => $url,
        consumer_secret => $c->app->config->{_openid_secret},
        args => \%params,
    );

    my $err_handler = sub ($err, $txt) {
        $c->app->log->error("OpenID: $err: $txt. Consider a report to the authentication server administrators.");
        $c->flash(error => "$err: $txt. Please retry again. "
              . 'If this reproduces please report the problem to the system administrators.');
        return (error => 0);
    };

    $csr->handle_server_response(
        not_openid => sub () {
            my $op_uri = $params{'openid.op_endpoint'} // '';
            $err_handler->('Failed to login', "OpenID provider '$op_uri' returned invalid data on a login attempt.");
        },
        setup_needed => sub ($setup_url) {
            # Redirect the user to $setup_url
            $setup_url = URI::Escape::uri_unescape($setup_url);
            $c->app->log->debug(qq{setup_url[$setup_url]});

            return (redirect => $setup_url, error => 0);
        },
        # Do something appropriate when the user hits "cancel" at the OP
        cancelled => sub () { },    # uncoverable statement
        verified => sub ($vident) { _handle_verified($c, $vident) },    # uncoverable statement
        error => sub (@args) { $err_handler->(@args) },    # uncoverable statement
    );

    return (redirect => decode_base64url($csr->args('return_page'), error => 0)) if $csr->args('return_page');
    return (redirect => 'index', error => 0);
}

1;
