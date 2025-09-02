# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Schema;
use OpenQA::Log qw(log_trace);
use Mojo::Util qw(hmac_sha1_sum secure_compare);
use Mojo::URL;

sub check ($self) {
    if ($self->app->config->{no_localhost_auth}) {
        return 1 if $self->is_local_request;
    }

    my $req = $self->req;
    my $headers = $req->headers;
    my $key = $headers->header('X-API-Key');
    my $hash = $headers->header('X-API-Hash');
    my $remote_timestamp = $headers->header('X-API-Microtime');
    my $user;
    log_trace($key ? "API key from client: *$key*" : 'No API key from client');

    my $schema = OpenQA::Schema->singleton;
    my $api_key = $schema->resultset('ApiKeys')->find({key => $key});
    if ($api_key) {
        if ($self->_is_timestamp_valid(time, $remote_timestamp)) {
            my $exp = $api_key->t_expiration;
            # It has no expiration date or it's in the future
            if (!$exp || $exp->epoch > time) {
                if (my $secret = $api_key->secret) {
                    my $sum = hmac_sha1_sum($self->req->url->to_string . $remote_timestamp, $secret);
                    $user = $api_key->user;
                    log_trace(sprintf 'API auth by user: %s, operator: %d', $user->username, $user->is_operator);
                }
            }
        }
    }
    return 1 if ($user && $user->is_operator);

    $self->render(json => {error => 'Not authorized'}, status => 403);
    return undef;
}

sub auth ($self) {
    my $log = $self->app->log;

    # Browser with a logged in user
    my ($user, $reason) = (undef, 'Not authorized');
    if ($user = $self->current_user) {
        ($user, $reason) = (undef, 'Bad CSRF token!') unless $self->req->method eq 'GET' || $self->valid_csrf;
    }

    # No session (probably not a browser)
    else {

        # Personal access token
        if (($self->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/) {
            ($user, $reason) = $self->_token_auth($reason, $1);
        }
        elsif (my $userinfo = $self->req->url->to_abs->userinfo) {
            ($user, $reason) = $self->_token_auth($reason, $userinfo);
        }

        # API key
        elsif (my $key = $self->req->headers->header('X-API-Key')) {
            ($user, $reason) = $self->_key_auth($reason, $key);
        }
        else {
            $log->trace('No API key from client');
            $reason = 'no api key';
        }
    }

    if ($user) {
        $log->trace(sprintf 'API auth by user: %s, operator: %d', $user->username, $user->is_operator);
        $self->stash(current_user => {user => $user});
        return 1;
    }

    $self->render(json => {error => $reason}, status => 403);
    return 0;
}

sub auth_operator ($self) {
    return 0 if !$self->auth;
    return 1 if $self->is_operator || $self->is_admin;

    $self->render(json => {error => 'Administrator level required'}, status => 403);
    return 0;
}

sub auth_admin ($self) {
    return 0 if !$self->auth;
    return 1 if $self->is_admin;

    $self->render(json => {error => 'Administrator level required'}, status => 403);
    return 0;
}

sub _is_timestamp_valid ($self, $our_timestamp, $remote_timestamp) {
    my $log = $self->app->log;
    my $tolerance = $self->config->{api_hmac_time_tolerance}
      // 300;    # make extra sure this value is never empty to avoid security issues

    return 1 if (abs($our_timestamp - $remote_timestamp) <= $tolerance);
    $log->debug(
qq{Timestamp mismatch over ${tolerance}s; our_timestamp: $our_timestamp, X-API-Microtime (from worker): $remote_timestamp}
    );
    return 0;
}

sub _is_expired ($api_key) {
    my $exp = $api_key->t_expiration;

    # It has no expiration date or it's in the future
    return 0 if (!$exp || $exp->epoch > time);
    return 1;
}

sub _token_auth ($self, $reason, $userinfo) {
    my $log = $self->app->log;

    $reason = 'invalid personal access token';
    if ($userinfo =~ /^([^:]+):([^:]+):([^:]+)$/) {
        my ($username, $key, $secret) = ($1, $2, $3);
        $log->trace(qq{Personal access token for user "$username"});
        if ($self->is_local_request || $self->req->is_secure) {
            my $ip = $self->tx->remote_address;
            my $reject_msg = qq{Rejecting personal access token for user "$username" with ip "$ip"};
            if (my $api_key = $self->schema->resultset('ApiKeys')->find({key => $key})) {
                my $user = $api_key->user;
                my $name = $user->name;
                $self->stash(webhook_validation_secret => join(':', $name, $key, $secret));
                if ($user && secure_compare($username, $name)) {
                    return ($user, undef) if secure_compare($secret, $api_key->secret);
                    $log->debug("$reject_msg, wrong secret");
                }
                else { $log->debug(qq{$reject_msg, wrong username, expected "$name"}) }
            }
            else { $log->debug("$reject_msg, wrong key") }
        }
        else {
            $log->debug('Peronal access token can only be used via HTTPS or from localhost');
            $reason = 'personal access token can only be used via HTTPS or from localhost';
        }
    }
    else { $log->debug('Invalid personal access token from client') }

    return (undef, $reason);
}

sub _key_auth ($self, $reason, $key) {
    my $log = $self->app->log;

    $log->trace("API key from client: *$key*");
    if (my $api_key = $self->schema->resultset('ApiKeys')->find({key => $key})) {
        $log->trace(sprintf 'Key is for user "%s"', $api_key->user->username);

        my $headers = $self->req->headers;
        my $url = $self->req->url;
        my $msg = $url->path eq '/api/v1/auth' ? ($headers->header('X-Original-URI') // $url) : $url;
        my $hash = $headers->header('X-API-Hash');
        my $remote_timestamp = $headers->header('X-API-Microtime');
        my $our_timestamp = time;
        my $username = $api_key->user->username;

        return ($api_key->user, $reason)
          if $self->_valid_hmac($hash, $msg, $our_timestamp, $remote_timestamp, $api_key);

        my $reject_msg
          = sprintf 'Rejecting authentication for user "%s" with ip "%s", valid key "%s", secret "%s"',
          $username, $self->tx->remote_address, $api_key->key, $api_key->secret;
        if (!$self->_is_timestamp_valid($our_timestamp, $remote_timestamp)) {
            $reason = 'timestamp mismatch - check whether clocks on the local host and the web UI host are in sync';
        }
        elsif (_is_expired($api_key)) {
            $reason = 'api key expired';
        }
        else {
            $reason = 'unknown error (wrong secret?)';
        }
        $log->debug("$reject_msg, $reason");
    }
    elsif ($key) { $log->debug("API key \"$key\" not found") }

    return (undef, $reason);
}

sub _valid_hmac ($self, $hash, $request, $our_timestamp, $remote_timestamp, $api_key) {
    return 0 unless $self->_is_timestamp_valid($our_timestamp, $remote_timestamp);
    return 0 if _is_expired($api_key);
    return 0 unless $api_key->secret;

    my $base_url = $self->app->config->{global}->{base_url};
    my $base_path = $base_url ? Mojo::URL->new($base_url)->path->leading_slash(0) : '';
    my $sum = hmac_sha1_sum($base_path . $request . $remote_timestamp, $api_key->secret);
    return secure_compare($hash, $sum);
}

1;
