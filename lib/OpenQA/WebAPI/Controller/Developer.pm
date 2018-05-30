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
use Try::Tiny;
use Mojo::URL;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;
use JSON qw(decode_json);

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
sub find_current_job {
    my ($self) = @_;

    my $test_id = $self->param('testid') or return;
    my $jobs = $self->app->schema->resultset('Jobs');
    return $jobs->search({id => $test_id})->first;
}

# serves a simple HTML/JavaScript page to connect either
#  1. directly from browser to os-autoinst command server
#  2. or to connect via ws_proxy route defined above
# (option 1. is default; specify query parameter 'proxy=1' for 2.)
sub ws_console {
    my ($self) = @_;

    my $job = $self->find_current_job() or return $self->reply->not_found;
    my $use_proxy = $self->param('proxy') // 0;

    # determine web socket URL
    my $ws_url = determine_web_socket_url($job);
    if ($use_proxy) {
        $ws_url = $ws_url ? $self->url_for('developer_ws_proxy', testid => $job->id) : undef;
    }

    $self->stash(job       => $job);
    $self->stash(ws_url    => ($ws_url // ''));
    $self->stash(use_proxy => $use_proxy);
    return $self->render;
}

# provides a web socket connection acting as a proxy to interact with os-autoinst indirectly
sub ws_proxy {
    my ($self) = @_;

    # determine basic variables
    my $job  = $self->find_current_job() or return $self->reply->not_found;
    my $user = $self->current_user()     or return $self->reply->not_found;
    my $app  = $self->app;

    $app->log->debug('ws_proxy: client connected: ' . $user->name);

    # define variables for transactions
    my $java_script_tx = $self->tx;    # for connection from browser/JavaScript to this server
    my $cmd_srv_tx;                    # for connection from this server to os-autoinst command server

    # TODO: register development session, ensure only one development session is opened per job
    # my $development_sessions = $app->schema->resultset('DevelopmentSessions');
    # ...

    # define functions to push information to the JavaScript client
    my $send_message_to_java_script = sub {
        my ($type, $what, $data) = @_;
        $java_script_tx->send(
            {
                json => {
                    type => $type,
                    what => $what,
                    data => $data,
                }});
        OpenQA::Utils::log_debug("ws_proxy: $type: $what");
    };
    my $quit_development_session = sub {
        $java_script_tx->finish();
        # TODO: unregister development session
    };

    # determine url to os-autoinst command server
    my $cmd_srv_raw_url = determine_web_socket_url($job);
    if (!$cmd_srv_raw_url) {
        $app->log->debug('ws_proxy: attempt to open for job ' . $job->name . ' (' . $job->id . ')');
        $send_message_to_java_script->(error => 'os-autoinst command server not available, job is likely not running');
        $quit_development_session->();
    }

    # define function to start a websocket connection to os-autoinst for this developer session
    my $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url);
    my $connect_to_cmd_srv;
    $connect_to_cmd_srv = sub {
        $send_message_to_java_script->(info => 'connecting to os-autuinst command server at ' . $cmd_srv_raw_url);

        return $app->ua->websocket(
            $cmd_srv_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
                my ($ua, $tx) = @_;
                $cmd_srv_tx = $tx;

                # upgrade to ws connection if not already a websocket connection
                if (!$tx->is_websocket) {
                    my $location_header = ($tx->completed ? $tx->res->headers->location : undef);
                    if (!$location_header) {
                        $send_message_to_java_script->(error => 'unable to upgrade ws to command server');
                        return;
                    }
                    OpenQA::Utils::log_debug('ws_proxy: following ws redirection to: ' . $location_header);
                    $cmd_srv_url = $cmd_srv_url->parse($location_header);
                    $connect_to_cmd_srv->();
                    return;
                }

                # handle messages from os-autoinst command server
                $send_message_to_java_script->(info => 'connected to os-autoinst command server');
                $tx->on(
                    json => sub {
                        my ($tx, $json) = @_;
                        $send_message_to_java_script->(info => 'cmdsrvmsg', $json);
                    });

                # handle connection to os-autoinst command server being quit
                $tx->on(
                    finish => sub {
                        my (undef, $code, $reason) = @_;
                        # inform the JavaScript client
                        $send_message_to_java_script->(
                            error => 'connection to os-autoinst command server lost',
                            {
                                reason => $reason,
                                code   => $code,
                            });
                        # quit the development session; the user can just reopen the session to try again
                        $quit_development_session->();
                    });
            });
    };

    # start opening a websocket connection to os-autoinst instantly
    $connect_to_cmd_srv->();

    # define function to push information to the os-autoinst command server
    my $send_message_to_os_autoinst = sub {
        my ($msg) = @_;
        if (!$cmd_srv_tx) {
            $send_message_to_java_script->(
                error => 'failed to pass message to os-autoinst command server because not connected yet');
            return;
        }
        $cmd_srv_tx->send({json => $msg});
    };

    # TODO: handle messages from the JavaScript
    $self->on(
        message => sub {
            my ($tx, $msg) = @_;
            try {
                my $json = decode_json($msg);
                # return a simple echo
                $send_message_to_java_script->(info => 'echo', $json);

                # TODO: handle some internal messages, eg. to quit the development session

                # TODO: validate the messages before passing to command server
                $send_message_to_os_autoinst->($json);
            }
            catch {
                $send_message_to_java_script->(
                    warning => 'ignoring invalid json',
                    {
                        msg => $msg,
                    });
            };
        });

    # TODO: handle development session being quit from the JavaScript-side
    $self->on(
        finish => sub {
            $app->log->debug('ws_proxy: client disconnected: ' . $user->name);
            # TODO: mark development session as inactive
            # note: it is likely not useful to quit the development session instantly because the user
            #       might just have pressed the reload button
        });
}

1;
# vim: set sw=4 et:
