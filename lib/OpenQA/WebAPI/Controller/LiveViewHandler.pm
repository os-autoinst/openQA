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

package OpenQA::WebAPI::Controller::LiveViewHandler;
use strict;
use Try::Tiny;
use Mojo::URL;
use Mojo::Base 'OpenQA::WebAPI::Controller::Developer';
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;
use JSON qw(decode_json);

# notes: * routes in this package are served by LiveViewHandler rather than the regular WebAPI server
#        * using prefork is currently not possible

# define a whitelist of commands to be passed to os-autoinst via ws_proxy
my %allowed_os_autoinst_commands = (
    set_pause_at_test     => 1,
    resume_test_execution => 1,
);

# define global variable to store ws connections (tx) to isotovideo cmd srv for each job
my %cmd_srv_transactions_by_job;

# define global variable to store ws connections (tx) to JavaScript clients for each job
my %java_script_transactions_by_job;

# provides a web socket connection acting as a proxy to interact with os-autoinst indirectly
sub ws_proxy {
    my ($self) = @_;

    # determine basic variables
    my $job  = $self->find_current_job() or return $self->reply->not_found;
    my $user = $self->current_user()     or return $self->reply->not_found;
    my $app  = $self->app;
    my $job_id             = $job->id;
    my $user_id            = $user->id;
    my $developer_sessions = $app->schema->resultset('DeveloperSessions');

    $app->log->debug('ws_proxy: client connected: ' . $user->name);

    # define variables for transactions
    my $java_script_tx = $self->tx;    # for connection from browser/JavaScript to this server
    my $cmd_srv_tx;                    # for connection from this server to os-autoinst command server
    my $java_script_tx_id = "$job_id-$java_script_tx";
    push(@{$java_script_transactions_by_job{$job_id} //= []}, $java_script_tx);

    # register development session, ensure only one development session is opened per job
    my $developer_session = $developer_sessions->register($job_id, $user_id);
    if (!$developer_session) {
        return $self->render(
            json => {
                error => 'unable to create (further) development session'
            },
            status => 400
        );
    }

    # mark session as active
    $developer_session->update({ws_connection_count => \'ws_connection_count + 1'});    #'restore syntax highlighting

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
        my ($reason) = @_;

        # notify the JavaScript client
        $send_message_to_java_script->(
            info => 'quitting development session',
            {
                reason => $reason
            });

        # unregister the developer session if the last JavaScript client disconnects
        if (my $development_session = $developer_sessions->find({job_id => $job_id})) {
            $app->log->debug('ws_proxy: removing development session ' . $job->name . ' (' . $job->id . ')');
            $development_session->delete();
        }

      # finish connections to all JavaScript clients
      # note: we don't finish connections served by other prefork processes here, hence prefork musn't be used (for now)
        my $java_script_transactions = delete $java_script_transactions_by_job{$job_id};
        if ($java_script_transactions) {
            for my $java_script_tx (@$java_script_transactions) {
                $java_script_tx->finish();
            }
        }

        # finish connection to os-autoinst cmd srv
        if (my $cmd_srv_tx = $cmd_srv_transactions_by_job{$job_id}) {
            $app->log->debug(
                'ws_proxy: finishing connection to os-autoinst cmd srv for job ' . $job->name . ' (' . $job->id . ')');
            $cmd_srv_tx->finish();
        }
    };

    # determine url to os-autoinst command server
    my $cmd_srv_raw_url = OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job);
    if (!$cmd_srv_raw_url) {
        $app->log->debug('ws_proxy: attempt to open for job ' . $job->name . ' (' . $job->id . ')');
        $send_message_to_java_script->(error => 'os-autoinst command server not available, job is likely not running');
        $quit_development_session->('os-autoinst command server not available');
    }

    # define function to start a websocket connection to os-autoinst for this developer session
    my $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url);
    my $connect_to_cmd_srv;
    $connect_to_cmd_srv = sub {
        $send_message_to_java_script->(info => 'connecting to os-autuinst command server at ' . $cmd_srv_raw_url);

        # prevent opening the same connection to os-autoinst cmd srv twice
        my $existing_cmd_srv_tx = $cmd_srv_transactions_by_job{$job_id};
        if ($existing_cmd_srv_tx) {
            $send_message_to_java_script->(
                info => 'reusing previous connection to os-autuinst command server at ' . $cmd_srv_raw_url);
            return $cmd_srv_tx = $existing_cmd_srv_tx;
        }

        # start a new connection to os-autoinst cmd srv
        return $cmd_srv_transactions_by_job{$job_id} = $app->ua->websocket(
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
                        # prevent finishing the transaction again in $quit_development_session
                        $cmd_srv_transactions_by_job{$job_id} = undef;
                        # inform the JavaScript client
                        $send_message_to_java_script->(
                            error => 'connection to os-autoinst command server lost',
                            {
                                reason => $reason,
                                code   => $code,
                            });
                        # don't implement a re-connect here, just quit the development session
                        # (the user can just reopen the session to try again manually)
                        $quit_development_session->('disconnected from os-autoinst command server');
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

    # handle messages from the JavaScript
    #  * expecting valid JSON here in 'os-autoinst' compatible form, eg.
    #      {"cmd":"set_pause_at_test","name":"installation-welcome"}
    #  * a selected set of commands is passed to os-autoinst backend
    #  * some commands are handled internally
    $self->on(
        message => sub {
            my ($tx, $msg) = @_;
            try {
                my $json = decode_json($msg);
                my $cmd  = $json->{cmd};
                if (!$cmd) {
                    $send_message_to_java_script->(warning => 'ignoring invalid command');
                    return;
                }

                # handle some internal messages, for now just allow to quit the development session
                if ($cmd eq 'quit_development_session') {
                    $quit_development_session->('user canceled');
                    return;
                }

                # validate the messages before passing to command server
                if (!$allowed_os_autoinst_commands{$cmd}) {
                    $send_message_to_java_script->(warning => 'ignoring invalid command', {cmd => $cmd});
                    return;
                }

                # send message to os-autoinst; no need to send extra feedback to JavaScript client since
                # we just pass the feedback from os-autoinst back
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

    # handle web socket connection being quit from the JavaScript-side
    $self->on(
        finish => sub {
            $app->log->debug('ws_proxy: client disconnected: ' . $user->name);
            my $session = $developer_sessions->find({job_id => $job_id}) or return;
            # note: it is likely not useful to quit the development session instantly because the user
            #       might just have pressed the reload button
            $session->update({ws_connection_count => \'ws_connection_count - 1'});    #'restore syntax highlighting
        });
}

1;
# vim: set sw=4 et:
