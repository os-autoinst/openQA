# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Shared::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Schema;
use OpenQA::Log qw(log_debug);
use Mojo::Util qw(hmac_sha1_sum secure_compare);

sub check ($self) {
    if ($self->app->config->{no_localhost_auth}) {
        return 1 if $self->is_local_request;
    }

    my $req       = $self->req;
    my $headers   = $req->headers;
    my $key       = $headers->header('X-API-Key');
    my $hash      = $headers->header('X-API-Hash');
    my $timestamp = $headers->header('X-API-Microtime');
    my $user;
    log_debug($key ? "API key from client: *$key*" : 'No API key from client');

    my $schema  = OpenQA::Schema->singleton;
    my $api_key = $schema->resultset('ApiKeys')->find({key => $key});
    if ($api_key) {
        if (time - $timestamp <= 300) {
            my $exp = $api_key->t_expiration;
            # It has no expiration date or it's in the future
            if (!$exp || $exp->epoch > time) {
                if (my $secret = $api_key->secret) {
                    my $sum = hmac_sha1_sum($self->req->url->to_string . $timestamp, $secret);
                    $user = $api_key->user;
                    log_debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
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
        ($user, $reason) = (undef, 'Bad CSRF token!') unless $self->valid_csrf;
    }

    # No session (probably not a browser)
    else {
        my $headers = $self->req->headers;

        # Personal access token
        if (my $userinfo = $self->req->url->to_abs->userinfo) {
            $reason = 'invalid personal access token';
            if ($userinfo =~ /^([^:]+):([^:]+):([^:]+)$/) {
                my ($username, $key, $secret) = ($1, $2, $3);
                $log->debug(qq{Personal access token for user "$username"});
                if ($self->is_local_request || $self->req->is_secure) {
                    my $ip         = $self->tx->remote_address;
                    my $reject_msg = qq{Rejecting personal access token for user "$username" with ip "$ip"};
                    if (my $api_key = $self->schema->resultset('ApiKeys')->find({key => $key})) {
                        my $real_user = $api_key->user;
                        if ($real_user && secure_compare($real_user->username, $username)) {
                            if (secure_compare($api_key->secret, $secret)) { ($user, $reason) = ($real_user, undef) }
                            else                                           { $log->error("$reject_msg, wrong secret") }
                        }
                        else { $log->error("$reject_msg, wrong username") }
                    }
                    else { $log->error("$reject_msg, wrong key") }
                }
                else {
                    $log->debug('Peronal access token can only be used via HTTPS or from localhost');
                    $reason = 'personal access token can only be used via HTTPS or from localhost';
                }
            }
            else { $log->debug('Invalid personal access token from client') }
        }

        # API key
        elsif (my $key = $headers->header('X-API-Key')) {
            $log->debug("API key from client: *$key*");
            if (my $api_key = $self->schema->resultset('ApiKeys')->find({key => $key})) {
                $log->debug(sprintf 'Key is for user "%s"', $api_key->user->username);
                my $msg                = $self->req->url->to_string;
                my $hash               = $headers->header('X-API-Hash');
                my $timestamp          = $headers->header('X-API-Microtime');
                my $build_tx_timestamp = $headers->header('X-Build-Tx-Time');
                my $username           = $api_key->user->username;
                if ($self->_valid_hmac($hash, $msg, $build_tx_timestamp, $timestamp, $api_key)) {
                    $user = $api_key->user;
                }
                else {
                    my $log_msg
                      = sprintf 'Rejecting authentication for user "%s" with ip "%s", valid key "%s", secret "%s"',
                      $username, $self->tx->remote_address, $api_key->key, $api_key->secret;
                    if (!_is_timestamp_valid($build_tx_timestamp, $timestamp)) {
                        $reason = 'timestamp mismatch';
                        $log->warn("$log_msg, $reason");
                    }
                    elsif (_is_expired($api_key)) {
                        $reason = 'api key expired';
                        $log->info("$log_msg, $reason");
                    }
                    else {
                        $reason = 'unknown error (wrong secret?)';
                        $log->error("$log_msg, $reason");
                    }
                }
            }
            elsif ($key) { $log->error("API key \"$key\" not found") }
        }
        else {
            $log->debug('No API key from client');
            $reason = 'no api key';
        }
    }

    if ($user) {
        $log->debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
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

sub _is_timestamp_valid ($build_tx_timestamp, $timestamp) {
    return ($build_tx_timestamp - $timestamp <= 300);
}

sub _is_expired ($api_key) {
    my $exp = $api_key->t_expiration;

    # It has no expiration date or it's in the future
    return 0 if (!$exp || $exp->epoch > time);
    return 1;
}

sub _valid_hmac ($self, $hash, $request, $build_tx_timestamp, $timestamp, $api_key) {
    return 0 unless _is_timestamp_valid($build_tx_timestamp, $timestamp);
    return 0 if _is_expired($api_key);
    return 0 unless $api_key->secret;

    my $sum = hmac_sha1_sum($request . $timestamp, $api_key->secret);
    return $sum eq $hash;
}

1;
