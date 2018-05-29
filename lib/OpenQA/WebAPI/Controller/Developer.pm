# Copyright (C) 2018 SUSE LLC
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

package OpenQA::WebAPI::Controller::Developer;
use strict;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;

# returns the isotovideo web socket URL for the given job or undef if not available
sub determine_web_socket_url {
    my ($job) = @_;

    return unless $job->state eq OpenQA::Schema::Result::Jobs::RUNNING;
    my $worker    = $job->assigned_worker             or return;
    my $job_token = $worker->get_property('JOBTOKEN') or return;
    my $host      = $worker->host                     or return;
    my $port      = ($worker->get_property('QEMUPORT') // 20012) + 1;
    # FIXME: don't hardcode port
    return "ws://$host:$port/$job_token/ws";
}

# returns the job for the currently processed request
sub find_job {
    my ($self) = @_;

    my $test_id = $self->param('testid') or return;
    my $jobs = $self->app->schema->resultset('Jobs');
    return $jobs->search({id => $test_id})->first;
}

# serves a simple HTML/JavaScript page to connect directly from browser to os-autoinst command server
sub ws_console {
    my ($self) = @_;

    my $job = $self->find_job() or return $self->reply->not_found;
    $self->stash(job    => $job);
    $self->stash(ws_url => (determine_web_socket_url($job) // ''));
    return $self->render;
}

# provides a web socket connection acting as a proxy to interact with os-autoinst indirectly
sub ws_proxy {
    my ($self) = @_;
    my $job  = $self->find_job()     or return $self->reply->not_found;
    my $user = $self->current_user() or return $self->reply->not_found;
    my $app  = $self->app;
    my $client_id = sprintf '%s', $self->tx;

    $app->log->debug('Client connected: ' . $client_id);

    # TODO: register development session, ensure only one development session is opened per job
    # my $development_sessions = $app->schema->resultset('DevelopmentSessions');
    # ...

    # TODO: define functions to push information to the JavaScript client
    my $send_message_to_java_script = sub {

    };
    my $close_connection_to_java_script = sub {

    };

    # start opening a websocket connection to os-autoinst
    my $cmd_srv_url        = Mojo::URL::new(determine_web_socket_url($job));
    my $cmd_srv_tx;
    my $connect_to_cmd_srv = sub {
        return $app->ua->websocket(
            $cmd_srv_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
                my ($ua, $tx) = @_;
                $cmd_srv_tx = $tx;

                # upgrade to ws connection if not already a websocket connection
                if (!$tx->is_websocket) {
                    my $location_header = ($tx->completed ? $tx->res->headers->location : undef);
                    if (!$location_header) {
                        $send_message_to_java_script->('Unable to upgrade ws to command server');
                        return;
                    }
                    OpenQA::Utils::log_debug('ws_proxy: Following ws redirection to: ' . $location_header);
                    $cmd_srv_url = $ua_url->parse($cmd_srv_url);
                    $connect_to_cmd_srv->();
                    return;
                }

                # TODO: handle messages from os-autoinst command server
                $tx->on(
                    json => sub {
                        my ($tx, $json) = @_;
                    });

                # TODO: handle connection to os-autoinst command server being quit
                $tx->on(
                    finish => sub {
                        my (undef, $code, $reason) = @_;
                    });
            });
    };

    # TODO: define functions to push information to the os-autoinst command server
    my $send_message_to_os_autoinst = sub {

    };
    my $close_connection_to_os_autoinst = sub {

    };

    # TODO: handle messages from the JavaScript
    $self->on(
        message => sub {

        });

    # TODO: handle development session being quit from the JavaScript-side
    $self->on(
        finish => sub {

        });
}

1;
# vim: set sw=4 et:
