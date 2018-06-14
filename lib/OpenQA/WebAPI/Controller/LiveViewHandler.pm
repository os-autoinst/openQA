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
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use JSON 'decode_json';

# notes: * routes in this package are served by LiveViewHandler rather than the regular WebAPI server
#        * using prefork is currently not possible (see notes in send_message_to_java_script_clients and
#          quit_development_session)

# define a whitelist of commands to be passed to os-autoinst via ws_proxy
my %allowed_os_autoinst_commands = (
    set_pause_at_test     => 1,
    status                => 1,
    resume_test_execution => 1,
);

# define global variable to store ws connections (tx) to isotovideo cmd srv for each job
my %cmd_srv_transactions_by_job;

# define global variable to store ws connections (tx) to JavaScript clients for each job
my %java_script_transactions_by_job;

has(
    developer_sessions => sub {
        my ($self) = @_;
        return $self->app->schema->resultset('DeveloperSessions');
    });

# assigns a (fake) command server transaction for the specified job ID, used in the unit tests
sub set_fake_cmd_srv_transaction {
    my ($job_id, $fake_transaction) = @_;
    $cmd_srv_transactions_by_job{$job_id} = $fake_transaction;
}

# assigns (fake) JavaScript transactions for the specified job ID, used in the unit tests
sub set_fake_java_script_transaction {
    my ($job_id, $fake_transactions) = @_;
    $java_script_transactions_by_job{$job_id} = $fake_transactions;
}

# broadcasts a message to all JavaScript clients for the specified job ID
# note: we don't broadcast to connections served by other prefork processes here, hence
#       prefork musn't be used (for now)
sub send_message_to_java_script_clients {
    my ($self, $job_id, $type, $what, $data, $quit_on_finished) = @_;
    my $java_script_transactions_for_current_job = $java_script_transactions_by_job{$job_id} or return;
    my $outstanding_transmissions = scalar @$java_script_transactions_for_current_job;
    for my $java_script_tx (@$java_script_transactions_for_current_job) {
        $java_script_tx->send(
            {
                json => {
                    type => $type,
                    what => $what,
                    data => $data,
                }
            },
            sub {
                return unless ($quit_on_finished);
                return if ($outstanding_transmissions -= 1);
                $self->quit_development_session($job_id, $what);
            });
    }
}

# same as send_message_to_java_script_clients, but quits the development session after everything is sent
# note: used to report fatal errors within ws_proxy which happen *after* the development session has been established
#       and require the development session to be quit
#       (eg. connection to os-autoinst lost)
sub send_message_to_java_script_clients_and_quit {
    my ($self, $job_id, $type, $what, $data) = @_;
    return $self->send_message_to_java_script_clients($job_id, $type, $what, $data, 1);
}

# sends a message to a particular JavaScript client using the specified transaction and finishes the transaction if done
# note: used to report fatal errors within ws_proxy which happen *before* the development session has been established
#       (eg. invalid job/user or development session is locked by another user)
sub send_message_to_java_script_client_and_finish {
    my ($self, $java_script_tx, $type, $what, $data) = @_;
    $java_script_tx->send(
        {
            json => {
                type => $type,
                what => $what,
                data => $data,
            }
        },
        sub {
            $java_script_tx->finish();
        });

    # return the result of an 'on' call; otherwise Mojolicious expects a 'delayed response'
    return $self->on(finish => sub { });
}

# quits the developments session for the specified job ID
# note: we can not disconnect connections served by other prefork processes here, hence
#       prefork musn't be used (for now)
sub quit_development_session {
    my ($self, $job_id, $reason) = @_;

    # remove the session from the database
    $self->developer_sessions->unregister($job_id);

    # finish connections to all JavaScript clients
    if (my $java_script_transactions_for_current_job = delete $java_script_transactions_by_job{$job_id}) {
        $_->finish() for (@$java_script_transactions_for_current_job);
    }

    # finish connection to os-autoinst cmd srv
    if (my $cmd_srv_tx = delete $cmd_srv_transactions_by_job{$job_id}) {
        $self->app->log->debug('ws_proxy: finishing connection to os-autoinst cmd srv for job ' . $job_id);
        $cmd_srv_tx->finish() if $cmd_srv_tx->is_websocket();
    }
}

sub handle_message_from_java_script {
    my ($self, $job_id, $msg) = @_;

    # decode JSON
    my $json;
    try {
        $json = decode_json($msg);
    }
    catch {
        $self->send_message_to_java_script_clients(
            $job_id,
            warning => 'ignoring invalid json',
            {
                msg => $msg,
            });
    };
    return unless $json;

    # check command
    my $cmd = $json->{cmd};
    if (!$cmd) {
        $self->send_message_to_java_script_clients($job_id, warning => 'ignoring invalid command');
        return;
    }

    # handle some internal messages, for now just allow to quit the development session
    if ($cmd eq 'quit_development_session') {
        $self->quit_development_session($job_id, 'user canceled');
        return;
    }

    # validate the messages before passing to command server
    if (!$allowed_os_autoinst_commands{$cmd}) {
        $self->send_message_to_java_script_clients(
            $job_id,
            warning => 'ignoring invalid command',
            {cmd => $cmd});
        return;
    }

    # send message to os-autoinst; no need to send extra feedback to JavaScript client since
    # we just pass the feedback from os-autoinst back
    $self->send_message_to_os_autoinst($job_id, $json);
}

# connects to the os-autoinst command server for the specified job ID; re-uses an existing connection
sub connect_to_cmd_srv {
    my ($self, $job_id, $cmd_srv_raw_url, $cmd_srv_url) = @_;

    $self->send_message_to_java_script_clients($job_id,
        info => 'connecting to os-autoinst command server at ' . $cmd_srv_raw_url);

    # prevent opening the same connection to os-autoinst cmd srv twice
    if (my $cmd_srv_tx = $cmd_srv_transactions_by_job{$job_id}) {
        $self->query_os_autoinst_status($job_id);
        $self->send_message_to_java_script_clients($job_id,
            info => 'reusing previous connection to os-autoinst command server at ' . $cmd_srv_raw_url);
        return $cmd_srv_tx;
    }

    # initialize $cmd_srv_url as Mojo::URL if not done yet
    $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url) unless ($cmd_srv_url);

    # start a new connection to os-autoinst cmd srv
    return $cmd_srv_transactions_by_job{$job_id} = $self->app->ua->websocket(
        $cmd_srv_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;
            $cmd_srv_transactions_by_job{$job_id} = $tx;

            # upgrade to ws connection if not already a websocket connection
            if (!$tx->is_websocket) {
                my $location_header = ($tx->completed ? $tx->res->headers->location : undef);
                if (!$location_header) {
                    $self->send_message_to_java_script_clients_and_quit($job_id,
                        error => 'unable to upgrade ws to command server');
                    return;
                }
                OpenQA::Utils::log_debug('ws_proxy: following ws redirection to: ' . $location_header);
                $cmd_srv_url = $cmd_srv_url->parse($location_header);
                $self->connect_to_cmd_srv($job_id, $cmd_srv_raw_url, $cmd_srv_url);
                return;
            }

            # instantly query the os-autoinst status
            $self->query_os_autoinst_status($job_id);

            # handle messages from os-autoinst command server
            $self->send_message_to_java_script_clients($job_id, info => 'connected to os-autoinst command server');
            $tx->on(
                json => sub {
                    my ($tx, $json) = @_;
                    # extend the status information from os-autoinst with the session info
                    if ($json->{running}) {
                        if (my $session = $self->developer_sessions->find($job_id)) {
                            $json->{developer_name}               = $session->user->name;
                            $json->{developer_session_started_at} = $session->t_created;
                            $json->{developer_session_tab_count}  = $session->ws_connection_count;
                        }
                    }
                    $self->send_message_to_java_script_clients($job_id, info => 'cmdsrvmsg', $json);
                });

            # handle connection to os-autoinst command server being quit
            $tx->on(
                finish => sub {
                    my (undef, $code, $reason) = @_;
                    # prevent finishing the transaction again in $quit_development_session
                    $cmd_srv_transactions_by_job{$job_id} = undef;
                    # inform the JavaScript client
                    $self->send_message_to_java_script_clients_and_quit(
                        $job_id,
                        error => 'connection to os-autoinst command server lost',
                        {
                            reason => $reason,
                            code   => $code,
                        });
                    # don't implement a re-connect here, just quit the development session
                    # (the user can just reopen the session to try again manually)
                });
        });
}

# sends a message to the os-autoinst command server for the specified job ID
# note: the connection must have been opened before using connect_to_cmd_srv()
sub send_message_to_os_autoinst {
    my ($self, $job_id, $msg) = @_;

    my $cmd_srv_tx = $cmd_srv_transactions_by_job{$job_id};
    if (!$cmd_srv_tx) {
        $self->send_message_to_java_script_clients($job_id,
            error => 'failed to pass message to os-autoinst command server because not connected yet');
        return;
    }
    $cmd_srv_tx->send({json => $msg});
}

# queries the status from os-autoinst
sub query_os_autoinst_status {
    my ($self, $job_id) = @_;

    $self->send_message_to_os_autoinst($job_id, {
        cmd => 'status'
    });
}

# provides a web socket connection acting as a proxy to interact with os-autoinst indirectly
sub ws_proxy {
    my ($self, $status_only) = @_;

    # determine basic variables
    my $java_script_tx = $self->tx;
    my $job            = $self->find_current_job()
      or return $self->send_message_to_java_script_client_and_finish($java_script_tx, error => 'job not found');
    my $user;
    my $app                = $self->app;
    my $job_id             = $job->id;
    my $developer_sessions = $app->schema->resultset('DeveloperSessions');


    # add JavaScript transaction to the list of JavaScript transactions for this job
    # (needed for broadcasting to all clients)
    my $java_script_transactions_for_current_job = ($java_script_transactions_by_job{$job_id} //= []);
    push(@$java_script_transactions_for_current_job, $java_script_tx);

    # register development session, ensure only one development session is opened per job
    if (!$status_only) {
        $user = $self->current_user()
          or return $self->send_message_to_java_script_client_and_finish($java_script_tx, error => 'user not found');
        my $developer_session = $developer_sessions->register($job_id, $user->id);
        $app->log->debug('ws_proxy: client connected: ' . $user->name);
        if (!$developer_session) {
            return $self->send_message_to_java_script_client_and_finish($java_script_tx,
                error => 'unable to create (further) development session');
        }
        # mark session as active
        $developer_session->update({ws_connection_count => \'ws_connection_count + 1'});   #'restore syntax highlighting

    }


    # determine url to os-autoinst command server
    my $cmd_srv_raw_url = OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job);
    if (!$cmd_srv_raw_url) {
        $app->log->debug('ws_proxy: attempt to open for job ' . $job->name . ' (' . $job_id . ')');
        $self->send_message_to_java_script_clients_and_quit($job_id,
            error => 'os-autoinst command server not available, job is likely not running');
    }

    # start opening a websocket connection to os-autoinst instantly
    $self->connect_to_cmd_srv($job_id, $cmd_srv_raw_url) if ($cmd_srv_raw_url);


    if ($status_only) {
        $self->on(
            message => sub {
                $app->log->debug('');
            });
        return $self->on(finish => sub { });
    }
    # handle messages from the JavaScript
    #  * expecting valid JSON here in 'os-autoinst' compatible form, eg.
    #      {"cmd":"set_pause_at_test","name":"installation-welcome"}
    #  * a selected set of commands is passed to os-autoinst backend
    #  * some commands are handled internally
    $self->on(
        message => sub {
            my ($tx, $msg) = @_;
            $self->handle_message_from_java_script($job_id, $msg);
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

sub proxy_status {
    my ($self) = @_;
    #We just need status, but pass it anyways
    return $self->ws_proxy('status');
}

1;
# vim: set sw=4 et:
