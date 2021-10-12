# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::LiveHandler::Controller::LiveViewHandler;
use Mojo::Base 'Mojolicious::Controller';

use Try::Tiny;
use Mojo::URL;
use OpenQA::Log 'log_debug';
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Mojo::JSON 'decode_json';

# notes: * routes in this package are served by LiveViewHandler rather than the regular WebAPI server
#        * using prefork is currently not possible (see notes in send_message_to_java_script_clients and
#          quit_development_session)

# define a passlist of commands to be passed to os-autoinst via ws_proxy
use constant ALLOWED_OS_AUTOINST_COMMANDS => {
    set_pause_at_test => 1,
    set_pause_on_screen_mismatch => 1,
    set_pause_on_next_command => 1,
    set_assert_screen_timeout => 1,
    status => 1,
    resume_test_execution => 1,
};

# define error categories
use constant {
    ERROR_CATEGORY_CMDSRV_CONNECTION => 'cmdsrv-connection',
    ERROR_CATEGORY_BAD_CONFIGURATION => 'bad-configuration',
};

# define required major version and minimum minor version for os-autoinst command server's developer mode API
use constant OS_AUTOINST_DEVEL_MODE_MAJOR_VERSION => 1;
use constant OS_AUTOINST_DEVEL_MODE_MINOR_VERSION => 0;

has(
    developer_sessions => sub {
        return shift->app->schema->resultset('DeveloperSessions');
    });

# add attributes for accessing the applications' ws connections more conveniently
# -> ws connections/transactions to isotovideo cmd srv
has(
    cmd_srv_transactions_by_job => sub {
        return shift->app->cmd_srv_transactions_by_job;
    });
# -> development session ws connections/transactions to JavaScript clients for each job
has(
    devel_java_script_transactions_by_job => sub {
        return shift->app->devel_java_script_transactions_by_job;
    });
# -> status-only ws connections/transactions to JavaScript clients for each job
has(
    status_java_script_transactions_by_job => sub {
        return shift->app->status_java_script_transactions_by_job;
    });

# broadcasts a message to all JavaScript clients for the specified job ID
# note: we don't broadcast to connections served by other prefork processes here, hence
#       prefork mustn't be used (for now)
sub send_message_to_java_script_clients {
    my ($self, $job_id, $type, $what, $data, $status_code_to_quit_on_finished) = @_;

    my @all_java_script_transactions_for_job;
    for my $java_script_transaction_container ($self->devel_java_script_transactions_by_job,
        $self->status_java_script_transactions_by_job)
    {
        if (my $java_script_transactions_for_job = $java_script_transaction_container->{$job_id}) {
            push(@all_java_script_transactions_for_job, @$java_script_transactions_for_job);
        }
    }

    my $outstanding_transmissions = scalar @all_java_script_transactions_for_job;
    $_->send(
        {
            json => {
                type => $type,
                what => $what,
                data => $data,
            }
        },
        sub {
            return unless ($status_code_to_quit_on_finished);
            return if ($outstanding_transmissions -= 1);
            $self->finish_all_connections($job_id, $status_code_to_quit_on_finished);
        }) for (@all_java_script_transactions_for_job);
    return $outstanding_transmissions;
}

# same as send_message_to_java_script_clients, but quits the development session after everything is sent
# note: used to report fatal errors within ws_proxy which happen *after* the development session has been established
#       and require the development session to be quit
#       (eg. connection to os-autoinst lost)
sub send_message_to_java_script_clients_and_finish {
    my ($self, $job_id, $type, $what, $data, $status_code) = @_;

    # set status code (errors or normal quit)
    $status_code = ($type eq 'error' ? 1011 : 1000) unless ($status_code);

    return $self->send_message_to_java_script_clients($job_id, $type, $what, $data, $status_code);
}

# sends a message to a particular JavaScript client using the specified transaction and finishes the transaction if done
# note: used to report fatal errors within ws_proxy which happen *before* the development session has been established
#       (eg. invalid job/user or development session is locked by another user)
sub send_message_to_java_script_client_and_finish {
    my ($self, $java_script_tx, $type, $what, $data, $status_code) = @_;

    # set status code (errors or normal quit)
    $status_code = ($type eq 'error' ? 1011 : 1000) unless ($status_code);

    $java_script_tx->send(
        {
            json => {
                type => $type,
                what => $what,
                data => $data,
            }
        },
        sub {
            $java_script_tx->finish($status_code);
        });

    # return the result of an 'on' call; otherwise Mojolicious expects a 'delayed response'
    return $self->on(finish => sub { });
}

sub finish_all_connections {
    my ($self, $job_id, $status_code) = @_;

    for my $java_script_transaction_container ($self->devel_java_script_transactions_by_job,
        $self->status_java_script_transactions_by_job)
    {
        my $java_script_transactions_for_current_job = delete $java_script_transaction_container->{$job_id} or next;
        $_->finish($status_code) for (@$java_script_transactions_for_current_job);
    }
}

# quits the developments session for the specified job ID
# note: we can not disconnect connections served by other prefork processes here, hence
#       prefork mustn't be used (for now)
sub quit_development_session {
    my ($self, $job_id, $reason, $status_code) = @_;

    # set default status code to "normal closure"
    $status_code //= 1000;

    # unregister session in the database
    $self->developer_sessions->unregister($job_id);

    # finish connections to all development session JavaScript clients
    if (my $java_script_transactions_for_current_job = delete $self->devel_java_script_transactions_by_job->{$job_id}) {
        $_->finish($status_code) for (@$java_script_transactions_for_current_job);
    }

    # prevent finishing connection to os-autoinst cmd srv if still serving status-only clients and update
    #  the session info for those clients instead
    if (my $status_only_java_script_transactions = $self->status_java_script_transactions_by_job->{$job_id}) {
        if (@$status_only_java_script_transactions) {
            $self->send_session_info($job_id);
            return;
        }
    }

    # finish connection to os-autoinst cmd srv
    if (my $cmd_srv_tx = delete $self->cmd_srv_transactions_by_job->{$job_id}) {
        $self->app->log->debug('finishing connection to os-autoinst cmd srv for job ' . $job_id);
        $cmd_srv_tx->finish($status_code) if $cmd_srv_tx->is_websocket();
    }
}

# checks whether the os-autoinst developer mode version reported by the specified status info it compatible
sub check_os_autoinst_devel_mode_version {
    my ($self, $status_info) = @_;

    my $major_version = $status_info->{devel_mode_major_version} //= 0;
    my $minor_version = $status_info->{devel_mode_minor_version} //= 0;
    return 0 if ($major_version ne OS_AUTOINST_DEVEL_MODE_MAJOR_VERSION);
    return 0 if ($minor_version lt OS_AUTOINST_DEVEL_MODE_MINOR_VERSION);
    return 1;
}

# handles a message from the java script web socket connection (not status-only)
#  * expecting valid JSON here in 'os-autoinst' compatible form, eg.
#      {"cmd":"set_pause_at_test","name":"installation-welcome"}
#  * a selected set of commands is passed to os-autoinst backend
#  * some commands are handled internally
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
    if (!ALLOWED_OS_AUTOINST_COMMANDS->{$cmd}) {
        $self->send_message_to_java_script_clients(
            $job_id,
            warning => 'ignoring invalid command',
            {cmd => $cmd});
        return;
    }

    # invoke special handler for the command before passing it to the command server
    if (my $handler = $self->can('_handle_command_' . $cmd)) {
        $handler->($self, $job_id, $json) or return;
    }

    # send message to os-autoinst; no need to send extra feedback to JavaScript client since
    # we just pass the feedback from os-autoinst back
    $self->send_message_to_os_autoinst($job_id, $json);
}

# attaches new needles to the resume command before passing it to the command server (called in handle_message_from_java_script)
sub _handle_command_resume_test_execution {
    my ($self, $job_id, $json) = @_;

    # find job and needles
    my $schema = $self->app->schema;
    my $jobs = $schema->resultset('Jobs');
    my $needles = $schema->resultset('Needles');
    my $job = $jobs->find($job_id);
    if (!$job) {
        $self->app->log->warning('trying to resume job which does not exist: ' . $job_id);
        return;
    }
    my $job_t_started = $job->t_started;
    if (!$job_t_started) {
        $self->app->log->warning('trying to resume job which has not been started yet: ' . $job_id);
        return;
    }

    # add new needles since the job has been started
    $json->{new_needles} = [map { $_->to_json } $needles->new_needles_since($job_t_started, undef, 100)->all];

    return 1;
}

# handles a disconnect of the web socket connection (not status-only)
sub handle_disconnect_from_java_script_client {
    my ($self, $job_id, $java_script_tx, $user_name) = @_;

    $self->app->log->debug('client disconnected: ' . $user_name);

    $self->remove_java_script_transaction($job_id, $self->devel_java_script_transactions_by_job, $java_script_tx);

    my $session = $self->developer_sessions->find({job_id => $job_id}) or return;
    $session->update({ws_connection_count => \'ws_connection_count - 1'});    #'restore syntax highlighting

    # send status update to remaining JavaScript clients
    $self->send_session_info($job_id);
}

sub find_upload_progress {
    my ($self, $job_id) = @_;

    my $workers = $self->app->schema->resultset('Workers');
    my $worker = $workers->find({job_id => $job_id}) or return undef;
    return $worker->upload_progress;
}

# extends the status info hash from os-autoinst with the session info and worker info
sub add_further_info_to_hash {
    my ($self, $job_id, $hash) = @_;
    if (my $session = $self->developer_sessions->find($job_id)) {
        my $user = $session->user;
        $hash->{developer_id} = $user->id;
        $hash->{developer_name} = $user->name;
        $hash->{developer_session_started_at} = $session->t_created;
        $hash->{developer_session_tab_count} = $session->ws_connection_count;
    }
    else {
        $hash->{developer_id} = undef;
        $hash->{developer_name} = undef;
        $hash->{developer_session_started_at} = undef;
        $hash->{developer_session_tab_count} = 0;
    }
    my $progress_info = $self->find_upload_progress($job_id) // {};
    for my $key (qw(outstanding_images outstanding_files upload_up_to_current_module)) {
        $hash->{$key} = $progress_info->{$key};
    }
}

# broadcasts a message from os-autoinst to js clients; checks the version and adds the session info if the message is the status hash
sub handle_message_from_os_autoinst {
    my ($self, $job_id, $json) = @_;

    my $is_status_message = defined($json->{running});
    if ($is_status_message) {
        if (!$self->check_os_autoinst_devel_mode_version($json)) {
            my $actual_version_str = "$json->{devel_mode_major_version}.$json->{devel_mode_minor_version}";
            my $required_version_str
              = OS_AUTOINST_DEVEL_MODE_MAJOR_VERSION . '.' . OS_AUTOINST_DEVEL_MODE_MINOR_VERSION;
            my $disconnect_reason
              = "os-autoinst version \"$actual_version_str\" is incompatible, version \"$required_version_str\" is required";
            $self->disconnect_from_os_autoinst($job_id, $disconnect_reason);
            return;
        }
        $self->add_further_info_to_hash($job_id, $json);
    }
    $self->send_message_to_java_script_clients($job_id, info => 'cmdsrvmsg', $json);
}

# disconnects all js clients and resets the os-autoinst connection
sub handle_disconnect_from_os_autoinst {
    my ($self, $job_id, $code, $reason) = @_;

    # prevent finishing the transaction twice
    $self->cmd_srv_transactions_by_job->{$job_id} = undef;
    # inform the JavaScript client
    $self->send_message_to_java_script_clients_and_finish(
        $job_id,
        error => 'connection to os-autoinst command server lost',
        {
            reason => $reason,
            code => $code,
            category => ERROR_CATEGORY_CMDSRV_CONNECTION,
        });
    # don't implement a re-connect here, just quit the development session
    # (the user can just reopen the session to try again manually)
}

# connects to the os-autoinst command server for the specified job ID; re-uses an existing connection
sub connect_to_cmd_srv {
    my ($self, $job_id, $cmd_srv_raw_url, $cmd_srv_url) = @_;

    log_debug("connecting to os-autoinst command server for job $job_id at $cmd_srv_raw_url");
    $self->send_message_to_java_script_clients($job_id,
        info => 'connecting to os-autoinst command server at ' . $cmd_srv_raw_url);

    # prevent opening the same connection to os-autoinst cmd srv twice
    if (my $cmd_srv_tx = $self->cmd_srv_transactions_by_job->{$job_id}) {
        $self->query_os_autoinst_status($job_id);
        $self->send_message_to_java_script_clients($job_id,
            info => 'reusing previous connection to os-autoinst command server at ' . $cmd_srv_raw_url);
        return $cmd_srv_tx;
    }

    # initialize $cmd_srv_url as Mojo::URL if not done yet
    $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url) unless ($cmd_srv_url);

    # start a new connection to os-autoinst cmd srv
    return $self->app->ua->websocket(
        $cmd_srv_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;

            # upgrade to ws connection if not already a websocket connection
            return $self->send_message_to_java_script_clients_and_finish($job_id,
                error => 'unable to upgrade ws to command server')
              unless $tx->is_websocket;

# assign transaction: don't do this before to prevent regular HTTP connections to be used in send_message_to_os_autoinst
            $self->cmd_srv_transactions_by_job->{$job_id} = $tx;

            # instantly query the os-autoinst status
            $self->query_os_autoinst_status($job_id);

            # handle messages from os-autoinst command server
            $self->send_message_to_java_script_clients($job_id, info => 'connected to os-autoinst command server');
            $tx->on(
                json => sub {
                    my ($tx, $json) = @_;
                    $self->handle_message_from_os_autoinst($job_id, $json);
                });

            # handle connection to os-autoinst command server being quit
            $tx->on(
                finish => sub {
                    my ($tx, $code, $reason) = @_;
                    $self->handle_disconnect_from_os_autoinst($job_id, $code, $reason);
                });
        });
}

# sends a message to the os-autoinst command server for the specified job ID
# note: the connection must have been opened before using connect_to_cmd_srv()
sub send_message_to_os_autoinst {
    my ($self, $job_id, $msg) = @_;

    my $cmd_srv_tx = $self->cmd_srv_transactions_by_job->{$job_id};
    if (!$cmd_srv_tx) {
        $self->send_message_to_java_script_clients($job_id,
            error => 'failed to pass message to os-autoinst command server because not connected yet');
        return;
    }
    $cmd_srv_tx->send({json => $msg});
}

# disconnects explicitly from os-autoinst command server, suppressing the usual handling when disconnecting from
# os-autoinst
# note: This connection is actually not supposed to be cancelled from the liveviewhandler's side. The only exception
#       is when a bad configuration (such as an incompatible version) is detected.
sub disconnect_from_os_autoinst {
    my ($self, $job_id, $reason, $status_code) = @_;

    # find relevant transaction and skip if there nothing to do if already disconnected
    my $cmd_srv_tx = $self->cmd_srv_transactions_by_job->{$job_id};
    return unless ($cmd_srv_tx);

    # assume disconnecting due to an error by default
    $status_code //= 1011;

    # prevent the usual handling when disconnecting from os-autoinst
    $self->cmd_srv_transactions_by_job->{$job_id} = undef;

    $cmd_srv_tx->finish($status_code);

    # inform the JavaScript clients and disconnect from them as well
    $self->send_message_to_java_script_clients_and_finish(
        $job_id,
        error => $reason,
        {
            code => $status_code,
            category => ERROR_CATEGORY_BAD_CONFIGURATION,
        });
}

# sends information about the developer session to all JavaScript clients
sub send_session_info {
    my ($self, $job_id) = @_;

    my %status_info;
    $self->add_further_info_to_hash($job_id, \%status_info);
    $self->send_message_to_java_script_clients($job_id, info => 'cmdsrvmsg', \%status_info);
}

# queries the status from os-autoinst
sub query_os_autoinst_status {
    my ($self, $job_id) = @_;

    $self->send_message_to_os_autoinst(
        $job_id,
        {
            cmd => 'status'
        });
}

# removes the specified JavaScript transaction from the specified container/job
sub remove_java_script_transaction {
    my ($self, $job_id, $container, $transaction) = @_;

    my $transactions = $container->{$job_id} or return;
    @$transactions = map { $_ == $transaction ? () : $_ } @$transactions;
}

# note: functions above are just helper, the methods which are actually registered routes start here

# provides a web socket connection acting as a proxy to interact with os-autoinst indirectly
sub ws_proxy {
    my ($self, $status_only) = @_;

    # determine basic variables
    my $java_script_tx = $self->tx;
    return $self->send_message_to_java_script_client_and_finish($java_script_tx, error => 'job not found')
      unless my $job = $self->find_current_job;
    my $user;
    my $user_id;
    my $app = $self->app;
    my $job_id = $job->id;
    my $developer_sessions = $app->schema->resultset('DeveloperSessions');

    # register development session, ensure only one development session is opened per job
    if (!$status_only) {
        $user = $self->current_user()
          or return $self->send_message_to_java_script_client_and_finish($java_script_tx, error => 'user not found');
        $user_id = $user->id;
        $java_script_tx->{user_id} = $user_id;
        my $developer_session = $developer_sessions->register($job_id, $user_id);
        $app->log->debug('client connected: ' . $user->name);
        if (!$developer_session) {
            return $self->send_message_to_java_script_client_and_finish($java_script_tx,
                error => 'unable to create (further) development session');
        }
        # mark session as active
        $developer_session->update({ws_connection_count => \'ws_connection_count + 1'});   #'restore syntax highlighting
    }

    # add JavaScript transaction to the list of JavaScript transactions for this job
    # (needed for broadcasting to all clients)
    my $java_script_transaction_container
      = $status_only ? $self->status_java_script_transactions_by_job : $self->devel_java_script_transactions_by_job;
    my $java_script_transactions_for_current_job = ($java_script_transaction_container->{$job_id} //= []);
    push(@$java_script_transactions_for_current_job, $java_script_tx);

    # determine url to os-autoinst command server
    my $cmd_srv_raw_url = $self->determine_os_autoinst_web_socket_url($job);
    if (!$cmd_srv_raw_url) {
        $app->log->debug('attempt to open ws proxy for job '
              . $job->name . ' ('
              . $job_id
              . ') where URL to os-autoinst command server is unknown');
        $self->send_message_to_java_script_clients_and_finish(
            $job_id,
            error => 'os-autoinst command server not available, job is likely not running',
            {
                reason => 'URL to command server unknown',
                category => ERROR_CATEGORY_CMDSRV_CONNECTION,
            });
    }

    # start opening a websocket connection to os-autoinst instantly
    $self->connect_to_cmd_srv($job_id, $cmd_srv_raw_url) if ($cmd_srv_raw_url);

    # don't react to any messages from the JavaScript client if serving the status-only route
    if ($status_only) {
        $self->on(message => sub { });
        return $self->on(
            finish => sub {
                $self->remove_java_script_transaction($job_id, $self->status_java_script_transactions_by_job,
                    $java_script_tx);
            });
    }

    # handle messages/disconnect from the JavaScript client (not status-only)
    $self->on(
        message => sub {
            my ($tx, $msg) = @_;
            $self->handle_message_from_java_script($job_id, $msg);
        });
    $self->on(
        finish => sub {
            $self->handle_disconnect_from_java_script_client($job_id, $java_script_tx, $user->name);
        });
}

# provides a status-only version of ws_proxy defined above
sub proxy_status {
    my ($self) = @_;
    return $self->ws_proxy('status');
}

# handles the request by the worker to post the upload progress
sub post_upload_progress {
    my ($self) = @_;

    # handle errors
    return $self->render(json => {error => 'No progress information provided'}, status => 400)
      unless my $progress_info = $self->req->json;
    return $self->render(json => {error => 'The job ID does not refer to a running job'}, status => 400)
      unless my $job = $self->find_current_job;
    my $job_id = $job->id;
    return $self->render(json => {error => 'The job as no assigned worker'}, status => 400)
      unless my $worker = $job->assigned_worker;

    # save upload progress so it can be included in the status info which is emitted when a new client connects
    $worker->update({upload_progress => $progress_info});

    # broadcast the upload progress to all connected java script web socket clients for this job
    my $broadcast_count
      = $self->send_message_to_java_script_clients($job_id, info => 'upload progress', $progress_info);
    return $self->render(json => {broadcast_count => $broadcast_count}, status => 200);
}

1;
