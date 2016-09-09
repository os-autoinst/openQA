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

package OpenQA::WebAPI::Controller::API::V1;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'hmac_sha1_sum';

sub auth {
    my $self = shift;
    my $user;

    my $reason = "Not authorized";

    if ($user = $self->current_user) {    # Browser with a logged in user
        unless ($self->valid_csrf) {
            $reason = "Bad CSRF token!";
            $user   = undef;
        }
    }
    else {                                # No session (probably not a browser)
        my $headers   = $self->req->headers;
        my $key       = $headers->header('X-API-Key');
        my $hash      = $headers->header('X-API-Hash');
        my $timestamp = $headers->header('X-API-Microtime');
        my $api_key;
        if ($key) {
            $self->app->log->debug("API key from client: *$key*");
            $api_key = $self->db->resultset("ApiKeys")->find({key => $key});
        }
        else {
            $self->app->log->debug("No API key from client.");
            $reason = "no api key";
        }
        if ($api_key) {
            $self->app->log->debug(sprintf "Key is for user '%s'", $api_key->user->username);
            my $msg = $self->req->url->to_string;
            $self->app->log->debug("$hash $msg");
            if ($self->_valid_hmac($hash, $msg, $timestamp, $api_key)) {
                $user = $api_key->user;
            }
            else {
                $self->app->log->error("hmac check failed");
                if (!_is_timestamp_valid($timestamp)) {
                    $reason = "timestamp mismatch";
                }
                elsif (_is_expired($api_key)) {
                    $reason = "api key expired";
                }
            }
        }
        elsif ($key) {
            $self->app->log->error(sprintf "api key '%s' not found", $key);
        }
    }

    if ($user) {
        $self->app->log->debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
        $self->stash(current_user => {user => $user});
        return 1;
    }

    $self->render(json => {error => $reason}, status => 403);
    return 0;
}

sub auth_operator {
    my ($self) = @_;
    return 0 if (!$self->auth);
    return 1 if ($self->is_operator || $self->is_admin);

    $self->render(json => {error => 'Administrator level required'}, status => 403);
    return 0;
}

sub auth_admin {
    my ($self) = @_;
    return 0 if (!$self->auth);
    return 1 if ($self->is_admin);

    $self->render(json => {error => 'Administrator level required'}, status => 403);
    return 0;
}

sub auth_jobtoken {
    my ($self)  = @_;
    my $headers = $self->req->headers;
    my $token   = $headers->header('X-API-JobToken');

    if ($token) {
        $self->app->log->debug("Received JobToken: $token");
        my $job = $self->db->resultset('Jobs')->search({'properties.key' => 'JOBTOKEN', 'properties.value' => $token}, {columns => ['id'], join => {worker => 'properties'}})->single;
        if ($job) {
            $self->stash('job_id', $job->id);
            $self->app->log->debug(sprintf('Found associated job %u', $job->id));
            return 1;
        }
    }
    else {
        $self->app->log->warn('No JobToken received!');
    }
    $self->render(json => {error => 'invalid jobtoken'}, status => 403);
    return;
}

sub _is_timestamp_valid {
    my ($timestamp) = @_;
    return (time - $timestamp <= 300);
}

sub _is_expired {
    my ($api_key) = @_;
    my $exp = $api_key->t_expiration;
    # It has no expiration date or it's in the future
    return 0 if (!$exp || $exp->epoch > time);
    return 1;
}

sub _valid_hmac {
    my $self = shift;
    my ($hash, $request, $timestamp, $api_key) = (shift, shift, shift, shift);

    return 0 unless _is_timestamp_valid($timestamp);
    return 0 if _is_expired($api_key);
    return 0 unless $api_key->secret;

    my $sum = hmac_sha1_sum($request . $timestamp, $api_key->secret);

    return $sum eq $hash;
}

1;
# vim: set sw=4 et:
