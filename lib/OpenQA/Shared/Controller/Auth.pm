# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Schema;
use OpenQA::Log qw(log_trace);
use OpenQA::Constants 'DEFAULT_ADMIN';
use Mojo::Util qw(hmac_sha1_sum secure_compare);
use Mojo::URL;
use Time::Seconds;
use DateTime;
use OpenQA::SSHKey qw(signature_payload verify_signature);

sub _auth_method_is_none ($self) { ($self->app->config->{auth}->{method} // '') eq 'None' }

sub check ($self) {
    my $config = $self->app->config;
    return 1 if $config->{no_localhost_auth} && $self->is_local_request;
    return 0 if $self->via_domain($config->{global}->{file_domain});

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
        if (($self->_is_timestamp_valid(time, $remote_timestamp))[0]) {
            my $exp = $api_key->t_expiration;
            # It has no expiration date or it's in the future
            if (!$exp || $exp->epoch > time) {
                if (my $secret = $api_key->secret) {
                    my $sum = hmac_sha1_sum($self->req->url->to_string . $remote_timestamp, $secret);
                    $user = $api_key->user if secure_compare($hash, $sum);
                    log_trace(sprintf 'API auth by user: %s, operator: %d', $user->username, $user->is_operator)
                      if $user;
                }
            }
        }
    }
    elsif ($self->_auth_method_is_none()) {
        $user = $schema->resultset('Users')->find({username => DEFAULT_ADMIN});
    }
    return 1 if ($user && $user->is_operator);

    $self->render(json => {error => 'Not authorized'}, status => 403);
    return undef;
}

sub auth ($self) {
    return 1 if $self->_auth;
    $self->render(json => {error => $self->stash('auth_error') // 'Not authorized'}, status => 403);
    return 0;
}

sub auth_maybe ($self) {
    $self->_auth;
    return 1;
}

sub _auth ($self) {
    my $log = $self->app->log;

    # Prevent authentication via file domain (where potentially untrusted HTML is served)
    if ($self->via_domain($self->config->{global}->{file_domain})) {
        $self->stash(auth_error => 'Forbidden via file domain');
        return 0;
    }

    # Browser with a logged in user
    my ($user, $reason) = (undef, 'Not authorized');
    if ($user = $self->current_user) {
        if ($self->req->method ne 'GET' && !$self->valid_csrf) {
            # Invalidate session-based auth if CSRF is missing; fallback to API headers if present
            $user = undef;
            $self->stash(auth_error => 'Bad CSRF token!');
            return 0 unless $self->is_api_request;
        }
    }

    # No session (probably not a browser)
    if (!$user) {
        # Personal access token, SSH key signature or API key
        if (defined(my $fingerprint = $self->req->headers->header('X-SSH-Key-Fingerprint'))) {
            ($user, $reason) = $self->_ssh_auth($reason, $fingerprint);
        }
        elsif (my $token = $self->_personal_access_token) {
            ($user, $reason) = $self->_token_auth($reason, $token);
        }
        elsif (my $key = $self->req->headers->header('X-API-Key')) {
            ($user, $reason) = $self->_key_auth($reason, $key);
        }
        elsif ($self->_auth_method_is_none()) {
            $user = $self->schema->resultset('Users')->find({username => DEFAULT_ADMIN});
            $reason = undef;
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

    $self->stash(auth_error => $reason);
    return 0;
}

sub _personal_access_token ($self) {
    return $1 if (($self->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/);
    return $self->req->url->to_abs->userinfo;
}

sub auth_operator ($self) {
    return 0 if !$self->auth;
    return 1 if $self->is_operator || $self->is_admin;

    $self->render(json => {error => 'Operator level required'}, status => 403);
    return 0;
}

sub auth_admin ($self) {
    return 0 if !$self->auth;
    return 1 if $self->is_admin;

    $self->render(json => {error => 'Administrator level required'}, status => 403);
    return 0;
}

sub _ssh_auth ($self, $reason, $fingerprint) {
    my $log = $self->app->log;
    my $headers = $self->req->headers;
    return (undef, 'SSH and API key authentication cannot be combined')
      if defined $headers->header('X-API-Key')
      || defined $headers->header('X-API-Hash')
      || defined $self->_personal_access_token;

    my $ssh_key = $self->schema->resultset('SshKeys')->find({fingerprint => $fingerprint});
    unless ($ssh_key) {
        $log->debug('Unknown SSH key fingerprint');
        return (undef, 'unknown SSH key');
    }

    my $user = $ssh_key->user;

    my $remote_timestamp = $headers->header('X-SSH-Microtime');
    return (undef, 'missing X-SSH-Microtime') unless defined $remote_timestamp;
    my ($timestamp_valid, $timestamp_reason) = $self->_is_timestamp_valid(time, $remote_timestamp);
    return (undef, $timestamp_reason) unless $timestamp_valid;

    return (undef, 'SSH signatures cannot cover multipart bodies') if $self->req->content->is_multipart;

    my $payload = signature_payload($self->req->method, $self->_base_path . $self->_signed_request_target,
        $remote_timestamp, $self->req->body);
    unless (verify_signature($ssh_key->public_key, $payload, $headers->header('X-SSH-Signature'))) {
        $log->debug(qq{Invalid SSH signature for user "${\$user->username}"});
        return (undef, 'invalid SSH signature');
    }

    $ssh_key->update({last_used => DateTime->now});
    $log->trace(sprintf 'SSH auth by user: %s', $user->username);
    return ($user, $reason);
}

sub _is_timestamp_valid ($self, $our_timestamp, $remote_timestamp) {
    my $log = $self->app->log;
    my $tolerance = $self->config->{api_hmac_time_tolerance}
      // ONE_MINUTE * 5;    # make extra sure this value is never empty to avoid security issues

    return (1, undef) if (abs($our_timestamp - $remote_timestamp) <= $tolerance);
    $log->debug(
qq{Timestamp mismatch over ${tolerance}s; our_timestamp: $our_timestamp, X-API-Microtime (from worker): $remote_timestamp}
    );
    my $tolerance_str = defined $tolerance ? "${tolerance}s" : 'unknown';
    my $client_ip = $self->tx ? $self->tx->remote_address : 'unknown';
    my $reason = 'timestamp mismatch - check whether clocks on the local host and the web UI host are in sync'
      . " (local host IP: $client_ip, server time: $our_timestamp, client time: $remote_timestamp, tolerance: $tolerance_str)";
    return (0, $reason);
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
                $self->stash(webhook_validation_secret => join ':', $name, $key, $secret);
                if ($user && secure_compare($username, $name)) {
                    return ($user, undef) if secure_compare($secret, $api_key->secret);
                    $log->debug("$reject_msg, wrong secret");
                }
                else { $log->debug(qq{$reject_msg, wrong username, expected "$name"}) }
            }
            else { $log->debug("$reject_msg, wrong key") }
        }
        else {
            $log->debug('Personal access token can only be used via HTTPS or from localhost');
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
        my $msg = $self->_signed_request_target;
        my $hash = $headers->header('X-API-Hash');
        my $remote_timestamp = $headers->header('X-API-Microtime');
        my $our_timestamp = time;
        my $username = $api_key->user->username;

        return ($api_key->user, $reason)
          if $self->_valid_hmac($hash, $msg, $our_timestamp, $remote_timestamp, $api_key);

        my $reject_msg
          = sprintf 'Rejecting authentication for user "%s" with ip "%s", valid key "%s", secret "%s"',
          $username, $self->tx->remote_address, $api_key->key, $api_key->secret;
        my ($timestamp_valid, $timestamp_reason) = $self->_is_timestamp_valid($our_timestamp, $remote_timestamp);
        if (!$timestamp_valid) {
            $reason = $timestamp_reason;
        }
        elsif (_is_expired($api_key)) {
            $reason = 'api key expired';
        }
        else {
            $reason = 'unknown error (wrong secret?)';
        }
        $log->debug("$reject_msg, $reason");
    }
    elsif ($key) { $log->debug(qq{API key "$key" not found}) }

    return (undef, $reason);
}

sub _signed_request_target ($self) {
    my $url = $self->req->url;
    return $url->path eq '/api/v1/auth' ? ($self->req->headers->header('X-Original-URI') // $url) : $url;
}

sub _base_path ($self) {
    my $base_url = $self->app->config->{global}->{base_url};
    return $base_url ? Mojo::URL->new($base_url)->path->leading_slash(0) : '';
}

sub _valid_hmac ($self, $hash, $request, $our_timestamp, $remote_timestamp, $api_key) {
    return 0 unless defined $hash;
    return 0 unless ($self->_is_timestamp_valid($our_timestamp, $remote_timestamp))[0];
    return 0 if _is_expired($api_key);
    return 0 unless $api_key->secret;

    my $sum = hmac_sha1_sum($self->_base_path . $request . $remote_timestamp, $api_key->secret);
    return secure_compare($hash, $sum);
}

1;
