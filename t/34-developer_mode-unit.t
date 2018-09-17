#! /usr/bin/perl

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

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::MockModule;
use OpenQA::Test::Case;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::WebAPI::Controller::Developer;
use OpenQA::WebAPI::Controller::LiveViewHandler;
use OpenQA::Client;
use Mojo::IOLoop;
use OpenQA::Utils qw(determine_web_ui_web_socket_url get_ws_status_only_url);

# mock OpenQA::Schema::Result::Jobs::cancel()
my $jobs_mock_module = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my @jobs_cancelled;
$jobs_mock_module->mock(
    cancel => sub {
        my ($job) = @_;
        push(@jobs_cancelled, $job->id);
    });

# mock OpenQA::IPC::websockets()
my $ipc_mock_module = Test::MockModule->new('OpenQA::IPC');
my @ipc_messages_for_websocket_server;
$ipc_mock_module->mock(
    websockets => sub {
        my $ipc_instance = shift;
        push(@ipc_messages_for_websocket_server, [@_]);
    });

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t             = Test::Mojo->new('OpenQA::WebAPI');
my $t_livehandler = Test::Mojo->new('OpenQA::LiveHandler');

# assigns a (fake) command server transaction for the specified job ID
sub set_fake_cmd_srv_transaction {
    my ($job_id, $fake_transaction) = @_;
    $t_livehandler->app->cmd_srv_transactions_by_job->{$job_id} = $fake_transaction;
}

# assigns (fake) development session JavaScript transactions for the specified job ID
sub set_fake_devel_java_script_transactions {
    my ($job_id, $fake_transactions) = @_;
    $t_livehandler->app->devel_java_script_transactions_by_job->{$job_id} = $fake_transactions;
}

# assigns (fake) status-only JavaScript transactions for the specified job ID
sub set_fake_status_java_script_transactions {
    my ($job_id, $fake_transactions) = @_;
    $t_livehandler->app->status_java_script_transactions_by_job->{$job_id} = $fake_transactions;
}

my $finished_handled_mock = Test::MockModule->new('OpenQA::WebAPI::Controller::LiveViewHandler');
my $finished_handled;
sub prepare_waiting_for_finished_handled {
    my $subroutine_name = 'handle_disconnect_from_java_script_client';
    $finished_handled = 0;
    $finished_handled_mock->mock(
        $subroutine_name => sub {
            $finished_handled_mock->original($subroutine_name)->(@_);
            $finished_handled = 1;
        });
}
sub wait_for_finished_handled {
    # wait until the finished event is handled (but at most 5 seconds)
    if (!$finished_handled) {
        my $timer = Mojo::IOLoop->timer(
            5.0 => sub {

            });
        Mojo::IOLoop->one_tick;
        Mojo::IOLoop->remove($timer);
    }

    $finished_handled_mock->unmock_all();
    fail('finished event not handled within 5 seconds') if (!$finished_handled);
}

# get CSRF token for auth
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
# note: since the openqa-livehandler daemon doesn't provide its own way to login, we
#       just copy the cookie with the required token from the regular user agent
$t_livehandler->ua->cookie_jar($t->ua->cookie_jar);

# login as arthur
sub login {
    my ($user_name) = @_;
    $test_case->login($t,             $user_name);
    $test_case->login($t_livehandler, $user_name);
}
login('arthur');

# get resultset
my $db                 = $t->app->db;
my $jobs               = $db->resultset('Jobs');
my $users              = $db->resultset('Users');
my $developer_sessions = $db->resultset('DeveloperSessions');
my $workers            = $db->resultset('Workers');

# the data to expect when no developer session is present
my %no_developer = (
    developer_id                 => undef,
    developer_name               => undef,
    developer_session_started_at => undef,
    developer_session_tab_count  => 0,
    outstanding_files            => undef,
    outstanding_images           => undef,
    upload_up_to_current_module  => undef,
);

subtest 'store upload progress as JSON in database on worker-level' => sub {
    my $worker = $workers->find({job_id => 99961});
    is($worker->upload_progress, undef, 'by default null');

    $worker->update({upload_progress => {some => 'json'}});
    $worker = $workers->find({job_id => 99961});
    is_deeply($worker->upload_progress, {some => 'json'}, 'get and set json data');

    $worker->unprepare_for_work();
    $worker = $workers->find({job_id => 99961});
    is($worker->upload_progress, undef, 'null after unpreparing');
};

subtest 'send message to JavaScript clients' => sub {
    # create fake java script connections for job 99961
    my @fake_java_script_transactions
      = (OpenQA::Test::FakeWebSocketTransaction->new(), OpenQA::Test::FakeWebSocketTransaction->new(),);
    my @fake_java_script_transactions2
      = (OpenQA::Test::FakeWebSocketTransaction->new(), OpenQA::Test::FakeWebSocketTransaction->new(),);
    set_fake_devel_java_script_transactions(99961, \@fake_java_script_transactions);
    set_fake_status_java_script_transactions(99961, \@fake_java_script_transactions2);

    # setup a new instance of the live view handler controller using the app from the test
    my $live_view_handler = OpenQA::WebAPI::Controller::LiveViewHandler->new();
    $live_view_handler->app($t_livehandler->app);

    # send message for job 99960 (should be ignored, only assigned transactions for job 99961)
    $live_view_handler->send_message_to_java_script_clients(99960, foo => 'bar', {some => 'data'});
    for my $tx (@fake_java_script_transactions) {
        is_deeply($tx->sent_messages, [], 'no messages for other jobs received');
    }

    # send message for job 99961 (should be broadcasted to all assigned transations)
    $live_view_handler->send_message_to_java_script_clients(99961, foo => 'bar', {some => 'data'});

    # send session info when no session present (should be broadcasted to all assigned transations)
    $live_view_handler->send_session_info(99961);

    # send session info when session present (should be broadcasted to all assigned transations)
    my $session = $developer_sessions->create(
        {
            job_id              => 99961,
            user_id             => 99901,
            ws_connection_count => 2,
        });
    my $session_t_created = $session->t_created;
    $live_view_handler->send_session_info(99961);
    $session->delete();

    # finish all clients
    is($_->finish_called, 0, 'no transactions finished so far')
      for (@fake_java_script_transactions, @fake_java_script_transactions2);
    $live_view_handler->send_message_to_java_script_clients_and_finish(99961, error => 'test', {some => 'error'});
    is($_->finish_called, 1, 'all transactions finished')
      for (@fake_java_script_transactions, @fake_java_script_transactions2);

    # assert the messages we've got
    is_deeply(
        $_->sent_messages,
        [
            {
                json => {
                    type => 'foo',
                    what => 'bar',
                    data => {some => 'data'}}
            },
            {
                json => {
                    type => 'info',
                    what => 'cmdsrvmsg',
                    data => \%no_developer
                }
            },
            {
                json => {
                    type => 'info',
                    what => 'cmdsrvmsg',
                    data => {
                        developer_id                 => 99901,
                        developer_name               => 'artie',
                        developer_session_started_at => $session_t_created,
                        developer_session_tab_count  => 2,
                        outstanding_files            => undef,
                        outstanding_images           => undef,
                        upload_up_to_current_module  => undef,
                    }}
            },
            {
                json => {
                    type => 'error',
                    what => 'test',
                    data => {
                        some => 'error',
                    }}
            },
        ],
        'message broadcasted to all clients'
    ) for (@fake_java_script_transactions, @fake_java_script_transactions2);
};

# remove fake transactions
set_fake_devel_java_script_transactions(99961, undef);
set_fake_status_java_script_transactions(99961, undef);

subtest 'send message to os-autoinst' => sub {
    # create fake java script connection for job 99961
    my $fake_java_script_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_devel_java_script_transactions(99960, [$fake_java_script_tx]);
    set_fake_devel_java_script_transactions(99961, [$fake_java_script_tx]);

    # create fake web socket connection to os-autoinst for job 99961
    my $fake_cmd_srv_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_cmd_srv_transaction(99961, $fake_cmd_srv_tx);

    # setup a new instance of the live view handler controller using the app from the test
    my $live_view_handler = OpenQA::WebAPI::Controller::LiveViewHandler->new();
    $live_view_handler->app($t_livehandler->app);

    # send message when not connected to os-autoinst
    # (just use job 99960 for which no fake transaction has been created)
    $live_view_handler->send_message_to_os_autoinst(99960 => {some => 'message'});
    is_deeply($fake_cmd_srv_tx->sent_messages, [], 'nothing passed to os-autoinst');
    is_deeply(
        $fake_java_script_tx->sent_messages,
        [
            {
                json => {
                    data => undef,
                    what => 'failed to pass message to os-autoinst command server because not connected yet',
                    type => 'error',
                }
            },
        ],
        'error about sending message to os-autoinst when not connected yet'
    );

    # send message when connected to os-autoinst
    # (just use job 99960 for which no fake transaction has been created)
    $live_view_handler->send_message_to_os_autoinst(99961 => {some => 'message'});
    is_deeply(
        $fake_cmd_srv_tx->sent_messages,
        [
            {
                json => {some => 'message'}}
        ],
        'message passed to os-autoinst'
    );
    $fake_cmd_srv_tx->clear_messages();

    # query os-autoinst status
    $live_view_handler->query_os_autoinst_status(99961);
    is_deeply(
        $fake_cmd_srv_tx->sent_messages,
        [
            {
                json => {cmd => 'status'}}
        ],
        'message passed to os-autoinst'
    );
};

# remove fake transactions
set_fake_devel_java_script_transactions(99960, undef);
set_fake_devel_java_script_transactions(99961, undef);
set_fake_cmd_srv_transaction(99961, undef);

subtest 'handle messages from JavaScript clients' => sub {
    # create fake java script connections for job 99961
    my $fake_java_script_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_devel_java_script_transactions(99961, [$fake_java_script_tx]);
    my $fake_status_only_java_script_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_status_java_script_transactions(99961, [$fake_status_only_java_script_tx]);
    my @java_script_transactions = ($fake_java_script_tx, $fake_status_only_java_script_tx,);

    # create fake web socket connection to os-autoinst for job 99961
    my $fake_cmd_srv_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_cmd_srv_transaction(99961, $fake_cmd_srv_tx);

    # setup a new instance of the live view handler controller using the app from the test
    my $live_view_handler = OpenQA::WebAPI::Controller::LiveViewHandler->new();
    $live_view_handler->app($t_livehandler->app);

    # send invalid JSON
    $live_view_handler->handle_message_from_java_script(99961, '{"foo"."bar"]');
    is_deeply(
        $_->sent_messages,
        [
            {
                json => {
                    data => {
                        msg => '{"foo"."bar"]'
                    },
                    what => 'ignoring invalid json',
                    type => 'warning',
                }}
        ],
        'warning about invalid JSON'
    ) for (@java_script_transactions);

    # send no command
    $_->clear_messages() for (@java_script_transactions);
    $live_view_handler->handle_message_from_java_script(99961, '{"foo":"bar"}');
    is_deeply(
        $_->sent_messages,
        [
            {
                json => {
                    data => undef,
                    what => 'ignoring invalid command',
                    type => 'warning',
                }}
        ],
        'warning about invalid command'
    ) for (@java_script_transactions);

    # send invalid command
    $_->clear_messages() for (@java_script_transactions);
    $live_view_handler->handle_message_from_java_script(99961, '{"cmd":"foo"}');
    is_deeply(
        $_->sent_messages,
        [
            {
                json => {
                    data => {
                        cmd => 'foo'
                    },
                    what => 'ignoring invalid command',
                    type => 'warning',
                }}
        ],
        'warning about invalid command (command actually not allowed)'
    ) for (@java_script_transactions);

    # send command which is expected to be passed to os-autoinst command server
    is_deeply($fake_cmd_srv_tx->sent_messages, [], 'nothing passed to os-autoinst so far');
    $live_view_handler->handle_message_from_java_script(99961,
        '{"cmd":"set_pause_at_test","name":"installation-welcome"}');
    is_deeply(
        $fake_cmd_srv_tx->sent_messages,
        [
            {
                json => {
                    cmd  => 'set_pause_at_test',
                    name => 'installation-welcome',
                }}
        ],
        'command sent to os-autoinst'
    );

    # send command to quit the session when status-only connections present
    $_->clear_messages() for (@java_script_transactions);
    is($fake_java_script_tx->finish_called, 0, 'no attempt to close the connection to JavaScript client so far');
    is($fake_cmd_srv_tx->finish_called,     0, 'no attempt to close the connection to os-autoinst so far');
    $live_view_handler->handle_message_from_java_script(99961, '{"cmd":"quit_development_session"}');
    is_deeply($fake_java_script_tx->sent_messages, [], 'no further messages to developer session JavaScript');
    is_deeply(
        $fake_status_only_java_script_tx->sent_messages,
        [
            {
                json => {
                    type => 'info',
                    what => 'cmdsrvmsg',
                    data => \%no_developer
                }
            },
        ],
        'status only JavaScript client notified about session quit'
    );
    ok($fake_java_script_tx->finish_called,              'connection to JavaScript client closed');
    ok(!$fake_status_only_java_script_tx->finish_called, 'connection to status-only JavaScript client still open');
    ok(!$fake_cmd_srv_tx->finish_called,
        'connection to os-autoinst not closed because status-only client still connected');

    # send command to quit the session when status-only connections present
    set_fake_devel_java_script_transactions(99961, [$fake_java_script_tx]);
    set_fake_status_java_script_transactions(99961, undef);
    $fake_java_script_tx->finish_called(0);
    $live_view_handler->handle_message_from_java_script(99961, '{"cmd":"quit_development_session"}');
    ok($fake_java_script_tx->finish_called, 'connection to JavaScript client closed');
    is_deeply($fake_java_script_tx->sent_messages, [], 'no further messages to developer session JavaScript');
    ok($fake_cmd_srv_tx->finish_called, 'connection to os-autoinst closed');
};

# remove fake transactions
set_fake_devel_java_script_transactions(99961, undef);
set_fake_cmd_srv_transaction(99961, undef);

subtest 'register developer session' => sub {
    is_deeply(\@ipc_messages_for_websocket_server, [], 'so far no IPC messages for worker')
      or diag explain \@ipc_messages_for_websocket_server;

    my $session = $developer_sessions->register(99963, 99901);
    ok($session, 'session created');
    is($session->job_id,  99963, 'job correctly passed');
    is($session->user_id, 99901, 'session correctly passed');

    my $session2 = $developer_sessions->register(99963, 99901);
    ok($session2, 'session created');
    is($developer_sessions->count, 1, 'existing session returned, no new row');

    is_deeply(
        \@ipc_messages_for_websocket_server,
        [['ws_send', 1, 'developer_session_start', 99963]],
        'worker notified exactly once about developer session'
    ) or diag explain \@ipc_messages_for_websocket_server;
    @ipc_messages_for_websocket_server = ();

    ok(!$developer_sessions->register(99963, 99902), 'locked for other users');
};

subtest 'unregister developer session' => sub {
    is_deeply(\@jobs_cancelled, [], 'no jobs cancelled so far');
    is($developer_sessions->unregister(99963, 99901), 1, 'returns 1 on successful deletion');
    is($developer_sessions->count, 1, 'session not completely deleted');
    is_deeply(\@jobs_cancelled, [99963], 'but the job has been cancelled');
    is($developer_sessions->unregister(99962, 99902), 0, 'returns 0 if session has not existed anyways');
};

subtest 'delete job or user deletes session' => sub {
    ok($developer_sessions->register(99963, 99901), 'create session (again)');

    $jobs->find(99963)->delete();
    is($developer_sessions->count, 0, 'no sessions left after job deleted');

    # FIXME: deleting a session when deleting a user doesn't work yet
    #        (deleting the user is currently prevented in that case)
    #ok($developer_sessions->register(99962, 99903), 'create session (again)');
    #$users->find(99903)->delete();
    #is($developer_sessions->count, 0, 'no sessions left after user deleted');
};

subtest 'URLs for command server and livehandler' => sub {
    my $job = $jobs->find(99961);
    my $worker = $workers->find({job_id => 99961});

    is(OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job),
        undef, 'no URL for job without assigned worker');

    $job->update({assigned_worker_id => $worker->id});
    is(OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job),
        undef, 'no URL for job without JOBTOKEN');

    $worker->set_property(JOBTOKEN => 'token99961');
    is(OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job),
        undef, 'no URL for job when worker has not propagated the URL yet');

    $worker->set_property(CMD_SRV_URL => 'http://remotehost:20013/token99964');
    is(
        OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job),
        'ws://remotehost:20013/token99961/ws',
        'URL for job with assigned worker'
    );

    $worker->set_property(WORKER_HOSTNAME => 'remotehost.qa');
    is(
        OpenQA::WebAPI::Controller::Developer::determine_os_autoinst_web_socket_url($job),
        'ws://remotehost.qa:20013/token99961/ws',
        'URL for job with assigned worker and WORKER_HOSTNAME property'
    );

    is(determine_web_ui_web_socket_url(99961), 'liveviewhandler/tests/99961/developer/ws-proxy', 'URL for livehandler');

    is(
        get_ws_status_only_url(99961),
        'liveviewhandler/tests/99961/developer/ws-proxy/status',
        'URL for livehandler status route'
    );
};

# save app and user agent to be able to restore
my ($app, $ua) = ($t_livehandler->app, $t_livehandler->ua);

subtest 'post upload progress' => sub {
    my $path = '/liveviewhandler/api/v1/jobs/99961/upload_progress';
    $t_livehandler->post_ok($path)->status_is(403, 'upload_progress route requires API authentification');

    # use OpenQA::Client for authentification
    $t_livehandler->ua(
        OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
    $t_livehandler->app($app);

    # test error handling
    $t_livehandler->post_ok('/liveviewhandler/api/v1/jobs/42/upload_progress', json => {})
      ->status_is(400, 'job does not exist');

    # test successful post
    my %upload_progress = (
        outstanding_images          => 3,
        outstanding_files           => 0,
        upload_up_to_current_module => 1,
    );
    $t_livehandler->post_ok($path, json => \%upload_progress)->status_is(200, 'post ok');
    my $worker = $workers->find({job_id => 99961});
    is_deeply($worker->upload_progress, \%upload_progress, 'progress stored on worker');

    # test whether info is included in info hash
    my $live_view_handler = OpenQA::WebAPI::Controller::LiveViewHandler->new();
    my $hash              = {};
    $live_view_handler->app($t_livehandler->app);
    $live_view_handler->add_further_info_to_hash(99961, $hash);
    is_deeply(
        $hash,
        {
            developer_id                 => undef,
            developer_name               => undef,
            developer_session_started_at => undef,
            developer_session_tab_count  => 0,
            %upload_progress
        },
        'upload progress added to info hash'
    );

    # revert state
    $worker->update({upload_progress => undef});
};

# restore app and user agent
$t_livehandler->ua($ua);
$t_livehandler->app($app);

subtest 'websocket proxy (connection from client to live view handler not mocked)' => sub {
    # dumps the state of the websocket connections established in the following subtests
    # note: not actually used after all, but useful during development
    sub dump_websocket_state {
        use Data::Dumper;
        print('finished: ' . Dumper($t_livehandler->{finished}) . "\n");
        print('messages: ' . Dumper($t_livehandler->{messages}) . "\n");
    }

    subtest 'job does not exist' => sub {
        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/54754/developer/ws-proxy',
            'establish ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'error',
                what => 'job not found',
                data => undef,
            });
        $t_livehandler->finished_ok(1011);

        is($developer_sessions->count, 0, 'no developer session after all');
    };

    subtest 'job without assigned worker' => sub {
        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/99962/developer/ws-proxy',
            'establish ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'error',
                what => 'unable to create (further) development session',
                data => undef,
            });
        $t_livehandler->finished_ok(1011);

        is($developer_sessions->count, 0, 'refuse to open developer session without assigned worker');
    };

    subtest 'job with assigned worker but no jobtoken' => sub {
        prepare_waiting_for_finished_handled();

        is_deeply(\@ipc_messages_for_websocket_server, [], 'so far no IPC messages for worker')
          or diag explain \@ipc_messages_for_websocket_server;

        my $worker = $workers->create(
            {
                job_id   => 99962,
                host     => 'foo',
                instance => 42
            });
        my $worker_id = $worker->id;

        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/99962/developer/ws-proxy',
            'establish ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'error',
                what => 'os-autoinst command server not available, job is likely not running',
                data => undef,
            });
        $t_livehandler->finished_ok(1011);

        wait_for_finished_handled();

        $worker->delete();

        is($developer_sessions->count, 1, 'developer session opened');
        my $developer_session = $developer_sessions->first;
        is($developer_session->ws_connection_count, 0,     'all ws connections finished');
        is($developer_session->job_id,              99962, 'job ID correct');
        is($developer_session->user_id,             99901, 'user ID correct');
        is_deeply(
            \@ipc_messages_for_websocket_server,
            [['ws_send', $worker_id, 'developer_session_start', 99962]],
            'worker about devel session notified'
        ) or diag explain \@ipc_messages_for_websocket_server;
    };

    subtest 'job with assigned worker, but os-autoinst not reachable' => sub {
        prepare_waiting_for_finished_handled();

        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/99961/developer/ws-proxy',
            'establish ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what => 'connecting to os-autoinst command server at ws://remotehost.qa:20013/token99961/ws',
                data => undef,
            });
        $t_livehandler->message_ok('another message received');
        $t_livehandler->json_message_is(
            {
                type => 'error',
                what => 'unable to upgrade ws to command server',
                data => undef,
            });
        $t_livehandler->finished_ok(1011);

        wait_for_finished_handled();

        my $developer_session = $developer_sessions->find(99961);
        is($developer_sessions->count,              2,     'another developer session opened');
        is($developer_session->ws_connection_count, 0,     'all ws connections finished');
        is($developer_session->user_id,             99901, 'user ID correct');
    };

    # create fake web socket connection to os-autoinst for job 99961
    my $fake_cmd_srv_tx = OpenQA::Test::FakeWebSocketTransaction->new();
    set_fake_cmd_srv_transaction(99961, $fake_cmd_srv_tx);

    subtest 'job with assigned worker, fake os-autoinst' => sub {
        prepare_waiting_for_finished_handled();

        # connect to ws proxy again, should use the fake connection now
        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/99961/developer/ws-proxy',
            'establish ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what => 'connecting to os-autoinst command server at ws://remotehost.qa:20013/token99961/ws',
                data => undef,
            });
        $t_livehandler->message_ok('another message received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what =>
                  'reusing previous connection to os-autoinst command server at ws://remotehost.qa:20013/token99961/ws',
                data => undef,
            });

        # handle test message from os-autoinst
        $fake_cmd_srv_tx->on(
            json => sub {
                my ($tx, $json) = @_;
                my $dummy_live_view_handler = OpenQA::WebAPI::Controller::LiveViewHandler->new();
                $dummy_live_view_handler->app($t_livehandler->app);
                $dummy_live_view_handler->handle_message_from_os_autoinst(99961, $json);
            });
        $fake_cmd_srv_tx->emit_json({foo => 'bar'});
        $t_livehandler->message_ok('message from command server received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what => 'cmdsrvmsg',
                data => {foo => 'bar'},
            });

        is($fake_cmd_srv_tx->finish_called, 0, 'no attempt to close the connection again');

        # check whether we finally opened a developer session
        my $developer_session = $developer_sessions->find(99961);
        is($developer_sessions->count,              2,     'no new developer session opened');
        is($developer_session->ws_connection_count, 1,     'ws connection finally kept open');
        is($developer_session->user_id,             99901, 'user ID correct');
        is(scalar @{$t_livehandler->app->devel_java_script_transactions_by_job->{99961} // []},
            1, 'devel js transactions populated');
        is(scalar @{$t_livehandler->app->status_java_script_transactions_by_job->{99961} // []},
            0, 'status only js transactions not affected');

        # closing connection will reset counter and bookkeeping of ongoing transations
        $t_livehandler->finish_ok();
        wait_for_finished_handled();

        is($developer_sessions->find(99961)->ws_connection_count, 0, 'ws connection finished');
        is(scalar @{$t_livehandler->app->devel_java_script_transactions_by_job->{99961} // []},
            0, 'devel js transactions cleaned');
    };

    subtest 'status-only route' => sub {
        # connect like in previous subtest, just use the status-only route this time
        $t_livehandler->websocket_ok(
            '/liveviewhandler/tests/99961/developer/ws-proxy/status',
            'establish status-only ws connection from JavaScript to livehandler'
        );
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what => 'connecting to os-autoinst command server at ws://remotehost.qa:20013/token99961/ws',
                data => undef,
            });
        $t_livehandler->message_ok('another message received');
        $t_livehandler->json_message_is(
            {
                type => 'info',
                what =>
                  'reusing previous connection to os-autoinst command server at ws://remotehost.qa:20013/token99961/ws',
                data => undef,
            });

        my $developer_session = $developer_sessions->find(99961);
        is($developer_sessions->count,              2, 'no new developer session opened');
        is($developer_session->ws_connection_count, 0, 'status-only conection not counted');
        is(scalar @{$t_livehandler->app->status_java_script_transactions_by_job->{99961} // []},
            1, 'status only js transactions populated');
        is(scalar @{$t_livehandler->app->devel_java_script_transactions_by_job->{99961} // []},
            0, 'devel js transactions not affected');

        $t_livehandler->finish_ok();
        is(scalar @{$t_livehandler->app->status_java_script_transactions_by_job->{99961} // []},
            0, 'status only js transactions cleaned');
    };

    subtest 'error handling' => sub {
        $t_livehandler->websocket_ok('/some/route');
        $t_livehandler->message_ok('message received');
        $t_livehandler->json_message_is(
            {
                type => 'error',
                what => 'route does not exist',
            });
        $t_livehandler->finished_ok(1011);

        $t_livehandler->get_ok('/some/route')->status_is(404);
        $t_livehandler->content_is("route does not exist\n", 'livehandler does not try to render a template');
    };

    # note: all subtests above were conducted as admin

    subtest 'access for regular users restricted' => sub {
        login('https://openid.camelot.uk/lancelot');

        # create and start ws transaction manually because Test::Mojo only provides websocket_ok() but
        #  we want to check the opposite here
        my $ua    = $t_livehandler->ua;
        my $ws_tx = $ua->build_websocket_tx('/liveviewhandler/tests/99961/developer/ws-proxy',
            'attempt to use proxy as regular user fails');
        $ua->start($ws_tx, sub { Mojo::IOLoop->stop; });
        Mojo::IOLoop->start;

        ok(!$ws_tx->is_websocket, 'ws handshake fails for non-operator');
        is($ws_tx->res->code, 403, 'instead we get 403');

        $t_livehandler->websocket_ok('/liveviewhandler/tests/99961/developer/ws-proxy/status',
            'status-only route accessible, though');
        $t_livehandler->message_ok('message received');
        $t_livehandler->finish_ok();
    };

    subtest 'access for operators granted' => sub {
        login('percival');
        $t_livehandler->websocket_ok('/liveviewhandler/tests/99961/developer/ws-proxy',
            'accessing proxy as operator is ok');
        $t_livehandler->message_ok('message received');
        $t_livehandler->finish_ok();
    };

    # note: This test might throw an exception at the end when using Mojo 7.83 - 7.91
    #       (see https://github.com/kraih/mojo/commit/61f6cbf22c7bf8eb4787bd1014d91ee2416c73e7).
};

done_testing();
