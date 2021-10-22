#!/usr/bin/env perl

# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Most;
use Mojo::IOLoop;
use Mojolicious;
use Test::Output 'combined_like';
use Test::Fatal;
use Test::Mojo;
use Test::MockModule;
use OpenQA::App;
use OpenQA::Test::Case;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Worker::WebUIConnection;
use OpenQA::Worker::CommandHandler;
use OpenQA::Worker::Job;
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT WORKER_COMMAND_QUIT WORKER_COMMAND_LIVELOG_STOP
  WORKER_COMMAND_LIVELOG_START WORKER_COMMAND_DEVELOPER_SESSION_START WORKER_COMMAND_GRAB_JOB
  WORKER_COMMAND_GRAB_JOBS WORKER_SR_API_FAILURE MAX_TIMER MIN_TIMER);
use OpenQA::Utils qw(in_range rand_range);

# use Mojo::Log and suppress debug messages
OpenQA::App->set_singleton(Mojolicious->new);
my $app = OpenQA::App->singleton;
$app->log->level('info');

like(
    exception {
        OpenQA::Worker::WebUIConnection->new('http://test-host', {});
    },
    qr{API key and secret are needed for the worker connecting http://test-host.*},
    'auth required',
);

my $client = OpenQA::Worker::WebUIConnection->new(
    'http://test-host',
    {
        apikey => 'foo',
        apisecret => 'bar'
    });

my @happened_events;
$client->on(
    status_changed => sub {
        my ($event_client, $event_data) = @_;

        is($event_client, $client, 'client passed correctly');
        is(ref $event_data, 'HASH', 'event data is a HASH');
        push(
            @happened_events,
            {
                status => $event_data->{status},
                error_message => $event_data->{error_message},
            });
    });

# assign a fake worker to the client
{
    package Test::FakeSettings;
    use Mojo::Base -base;
    has global_settings => sub { {RETRIES => 3, RETRY_DELAY => 10, RETRY_DELAY_IF_WEBUI_BUSY => 90} };
    has webui_host_specific_settings => sub { {} };
}
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number => 1;
    has worker_hostname => 'test_host';
    has current_webui_host => undef;
    has capabilities => sub { {fake_capabilities => 1} };
    has stop_current_job_called => 0;
    has is_stopping => 0;
    has current_error => undef;
    has current_job => undef;
    has has_pending_jobs => 0;
    has pending_job_ids => sub { []; };
    has current_job_ids => sub { []; };
    has is_busy => 0;
    has settings => sub { Test::FakeSettings->new; };
    has enqueued_job_info => undef;
    sub stop_current_job {
        my ($self, $reason) = @_;
        $self->stop_current_job_called($reason);
    }
    sub stop { shift->is_stopping(1); }
    sub status { {fake_status => 1, reason => 'some error'} }
    sub accept_job {
        my ($self, $client, $job_info) = @_;
        $self->current_job(OpenQA::Worker::Job->new($self, $client, $job_info));
    }
    sub enqueue_jobs_and_accept_first {
        my ($self, $client, $job_info) = @_;
        $self->enqueued_job_info($job_info);
    }
    sub find_current_or_pending_job {
        my ($self, $job_id) = @_;
        if (my $current_job = $self->current_job) {
            return $current_job if $current_job->id eq $job_id;
        }
        return undef;
    }
}
$client->worker(Test::FakeWorker->new);
$client->working_directory('t/');

is($client->status, 'new', 'client in status new');
like(
    exception {
        $client->send('get', '.');
    },
    qr{attempt to send command to web UI http://test-host with no worker ID.*},
    'registration required',
);

# mock OpenQA::Worker::Job so it starts/stops the livelog also if the backend isn't running
my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
$job_mock->redefine(start_livelog => sub { shift->{_livelog_viewers} = 1 });
$job_mock->redefine(stop_livelog => sub { shift->{_livelog_viewers} = 0 });

subtest 'attempt to register and send a command' => sub {
    # test registration failure
    $client->register;
    is($client->status, 'failed', 'client failed to register');

    # note: Successful registration is tested in e.g. `05-scheduler-full.t`.

    # assume we've been registered with worker ID 42
    $client->worker_id(42);

    # test failing REST API call ignoring errors
    my $callback_invoked = 0;
    $client->send(
        post => 'jobs/500/status',
        json => {status => 'running'},
        ignore_errors => 1,
        tries => 1,
        callback => sub {
            my ($res) = @_;
            is($res, undef, 'undefined result returned in the error case');
            $callback_invoked = 1;
        },
    );
    Mojo::IOLoop->start;
    is($callback_invoked, 1, 'callback has been invoked');
    is($client->worker->stop_current_job_called, 0, 'not attempted to stop current job');

    # test failing REST API call *not* ignoring errors
    $callback_invoked = 0;
    combined_like {
        $client->send(
            post => 'jobs/500/status',
            json => {status => 'running'},
            tries => 1,
            callback => sub {
                my ($res) = @_;
                is($res, undef, 'undefined result returned in the error case');
                $callback_invoked = 1;
            },
        );
        Mojo::IOLoop->start;
    }
    qr/Connection error: Can't connect:.*(remaining tries: 0)/s, 'error logged';
    is($callback_invoked, 1, 'callback has been invoked');
    is($client->worker->stop_current_job_called,
        0, 'not attempted to stop current job because it is from different web UI');
    $client->worker->current_webui_host('http://test-host');
    $callback_invoked = 0;
    combined_like {
        $client->send(
            post => 'jobs/500/status',
            json => {status => 'running'},
            tries => 1,
            callback => sub {
                my ($res) = @_;
                is($res, undef, 'undefined result returned in the error case');
                $callback_invoked = 1;
            },
        );
        Mojo::IOLoop->start;
    }
    qr/Connection error:.*(remaining tries: 0)/s, 'error logged';

    is($callback_invoked, 1, 'callback has been invoked');
    is($client->worker->stop_current_job_called,
        WORKER_SR_API_FAILURE, 'attempted to stop current job with reason "api-failure"');

    my $error_message = ref($happened_events[1]) eq 'HASH' ? delete $happened_events[1]->{error_message} : undef;
    (
        is_deeply(
            \@happened_events,
            [{status => 'registering', error_message => undef}, {status => 'failed'}],
            'events emitted',
          )
          and like(
            $error_message,
            qr{Failed to register at http://test-host - connection error: Can't connect:.*},
            'error message',
          )) or diag explain \@happened_events;
};


subtest 'retry behavior' => sub {
    # use fake Mojo::UserAgent and Mojo::Transaction
    {
        package Test::FakeTransaction;
        use Mojo::Base -base;
        has error => undef;
        has res => undef;
    }
    {
        package Test::FakeUserAgent;
        use Mojo::Base -base;
        has fake_error => undef;
        has start_count => 0;
        sub build_tx {
            my ($self, @args) = @_;
            return Test::FakeTransaction->new;
        }
        sub start {
            my ($self, $tx, $callback) = @_;
            $tx->error($self->fake_error);
            $self->start_count($self->start_count + 1);
            $callback->($self, $tx);
        }
    }
    my $fake_error = {message => 'some timeout'};
    my $fake_ua = Test::FakeUserAgent->new(fake_error => $fake_error);
    my $default_ua = $client->ua;
    $client->ua($fake_ua);

    # mock retry delay so tests don't take forever
    my $web_ui_connection_mock = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
    my $web_ui_supposed_to_be_considered_busy = 1;
    my $retry_delay_invoked = 0;
    $web_ui_connection_mock->redefine(
        _retry_delay => sub {
            my ($self, $is_webui_busy) = @_;
            is($is_webui_busy, $web_ui_supposed_to_be_considered_busy, 'retry delay applied accordingly');
            $retry_delay_invoked += 1;
            return 0;
        });

    # define arguments for send call
    my $callback_invoked = 0;
    my @send_args = (
        post => 'jobs/500/status',
        json => {status => 'running'},
        callback => sub {
            my ($res) = @_;
            is($res, undef, 'undefined result returned in the error case');
            $callback_invoked += 1;
        },
    );

    sub send_once {
        my ($send_args, $expected_re, $msg, @args) = @_;
        combined_like {
            $client->send(@$send_args, @args);
            Mojo::IOLoop->start;
        }
        $expected_re, $msg // 'attempts logged';
    }

    subtest 'retry after timeout' => sub {
        send_once(\@send_args,
qr/Connection error: some timeout \(remaining tries: 2\).*Connection error: some timeout \(remaining tries: 1\).*Connection error: some timeout \(remaining tries: 0\)/s
        );
        is($fake_ua->start_count, 3, 'tried 3 times');
        is($callback_invoked, 1, 'callback invoked exactly one time');

        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        my %codes_retry_ok = (
            408 => 'Request Timeout',
            425 => 'Too Early',
            502 => 'Bad Gateway (some timeout)',
        );
        my $start_count = 3;
        my $callback_count = 1;
        my $retry_delay_count = 2;
        for (sort keys %codes_retry_ok) {
            my $code = $fake_error->{code} = $_;
            send_once(\@send_args,
qr/$code response: some timeout \(remaining tries: 2\).*$code response: some timeout \(remaining tries: 1\).*$code response: some timeout \(remaining tries: 0\)/s
            );
            is($fake_ua->start_count, $start_count, "tried 3 times for $code");
            is($callback_invoked, $callback_count++, "callback invoked exactly one time for $code");
            is($retry_delay_invoked, $retry_delay_count, "retry delay queried for $code");
            $start_count += 3;
            $retry_delay_count += 2;
        }
    };

    subtest 'retry after unknown API error' => sub {
        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        $fake_error->{message} = 'some error';
        $fake_error->{code} = 500;
        $web_ui_supposed_to_be_considered_busy = undef;
        send_once(\@send_args,
            qr/500 response: some error \(remaining tries: 1\).*500 response: some error \(remaining tries: 0\)/s,
            undef, tries => 2);
        is($fake_ua->start_count, 2, 'tried 2 times');
        is($callback_invoked, 1, 'callback invoked exactly one time');
        is($retry_delay_invoked, 1, 'retry delay queried');
    };

    subtest 'no retry after 4XX (with exceptions)' => sub {
        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        my %codes_4xx = (
            400 => 'Not found',
            401 => 'Unauthorized',
            403 => 'Forbidden',
            404 => 'Not found',
            418 => 'I\'m a teapot',
            426 => 'Upgrade Required',
        );
        my $start_count = 1;
        my $callback_count = 1;
        for (sort keys %codes_4xx) {
            $fake_error->{code} = $_;
            $fake_error->{message} = $codes_4xx{$_};
            send_once(
                \@send_args,
                qr/$fake_error->{code} response: $fake_error->{message} \(remaining tries: 0\)/,
                "$fake_error->{code} logged"
            );
            is($fake_ua->start_count, $start_count++, "tried 1 time for $fake_error->{code}");
            is($callback_invoked, $callback_count++, "callback invoked exactly one time for $fake_error->{code}");
            is($retry_delay_invoked, 0, "retry delay not queried $fake_error->{code}");
        }
    };

    subtest 'no retry if ignoring errors' => sub {
        $callback_invoked = 0;
        $fake_ua->start_count(0);
        $client->send(@send_args, tries => 3, ignore_errors => 1);
        Mojo::IOLoop->start;
        is($fake_ua->start_count, 1, 'no retry attempts');
        is($callback_invoked, 1, 'callback invoked exactly one time');
        is($retry_delay_invoked, 0, 'retry delay not queried');
    };

    $client->ua($default_ua);
};

subtest 'retry delay configurable' => sub {
    is($client->_retry_delay(0), 10, 'default delay used from global settings');
    is($client->_retry_delay(1), 90, '"busy" delay used from global settings');

    $client->worker->settings->webui_host_specific_settings->{$client->webui_host} = {
        RETRY_DELAY => 30,
        RETRY_DELAY_IF_WEBUI_BUSY => 120,
    };
    is($client->_retry_delay(0), 30, 'default delay used from host-specific settings');
    is($client->_retry_delay(1), 120, '"busy" delay used from host-sepcific settings');
};

subtest 'send status' => sub {
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    $client->websocket_connection($ws);
    $client->send_status_interval(0.5);
    $client->send_status();
    is_deeply($ws->sent_messages, [{json => {fake_status => 1, reason => 'some error'}}], 'status sent')
      or diag explain $ws->sent_messages;
    combined_like { Mojo::IOLoop->one_tick } qr/some error.*checking again/, 'error logged in callback';
};

subtest 'quit' => sub {
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    my $callback_called = 0;
    my $callback = sub { $callback_called = 1; };

    subtest 'there is an active ws connection' => sub {
        $client->websocket_connection($ws);
        $client->quit($callback);
        is_deeply($ws->sent_messages, [{json => {type => 'quit'}}], 'quit sent')
          or diag explain $ws->sent_messages;
        Mojo::IOLoop->one_tick;
        ok($callback_called, 'callback passed to websocket send');
    };
    subtest 'there is no active ws connection' => sub {
        $callback_called = 0;
        $client->websocket_connection(undef);
        $client->quit($callback);
        Mojo::IOLoop->one_tick;
        ok($callback_called, 'callback nevertheless invoked on next tick');
    };
};

subtest 'rejecting jobs' => sub {
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    my $callback_called = 0;
    my $callback = sub { $callback_called = 1; };

    subtest 'rejecting job postponed while not connected' => sub {
        $client->websocket_connection(undef);
        $client->reject_jobs([1, 2, 3], 'just a test', $callback);
        is_deeply($ws->sent_messages, [], 'no message send when not connected')
          or diag explain $ws->sent_messages;
        ok(!$callback_called, 'callback not invoked so far');
    };
    subtest 'job rejected when connected' => sub {
        $client->websocket_connection($ws);
        $client->emit('connected');
        Mojo::IOLoop->one_tick;
        is_deeply(
            $ws->sent_messages,
            [{json => {type => 'rejected', job_ids => [1, 2, 3], reason => 'just a test'}}],
            'rejected sent when connected again'
        ) or diag explain $ws->sent_messages;
        ok($callback_called, 'callback invoked');
    };
};

subtest 'command handler' => sub {
    my $command_handler = OpenQA::Worker::CommandHandler->new($client);
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    my $worker = $client->worker;
    $client->websocket_connection($ws);

    # test at least some of the error cases
    combined_like { $command_handler->handle_command(undef, {}) }
    qr/Ignoring WS message without type from http:\/\/test-host.*/, 'ignoring non-result message without type';
    combined_like { $command_handler->handle_command(undef, {type => WORKER_COMMAND_LIVELOG_STOP, jobid => 1}) }
qr/Ignoring WS message from http:\/\/test-host with type livelog_stop and job ID 1 \(currently not executing a job\).*/,
      'ignoring job-specific message when no job running';
    $worker->current_error('some error');
    $app->log->level('debug');
    my %job = (id => 42, settings => {});
    combined_like { $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => \%job}) }
    qr/Refusing to grab job.*: some error/, 'ignoring grab_job while in error-state';

    my %job_info = (sequence => [$job{id}], data => {42 => \%job});
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOBS, job_info => \%job_info})
    }
    qr/Refusing to grab job.*: some error/, 'ignoring grab_jobs while in error-state';
    is($worker->current_job, undef, 'no job has been accepted while in error-state');

    $worker->current_error(undef);
    $worker->is_stopping(1);
    combined_like { $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => \%job}) }
    qr/Refusing to grab job.*: currently stopping/, 'ignoring grab_job while stopping';

    $app->log->level('info');
    $worker->is_stopping(0);

    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => {id => 'but no settings'}})
    }
    qr/Refusing to grab job.*: the provided job is invalid.*/, 'ignoring grab job if no valid job info provided';
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOBS, job_info => {sequence => ['foo']}})
    }
    qr/Refusing to grab jobs.*: the provided job info lacks job data or execution sequence.*/,
      'ignoring grab multiple jobs if job data';
    combined_like {
        $command_handler->handle_command(undef,
            {type => WORKER_COMMAND_GRAB_JOBS, job_info => {sequence => 'not an array', data => {42 => 'foo'}}})
    }
    qr/Refusing to grab jobs.*: the provided job info lacks execution sequence.*/,
      'ignoring grab multiple jobs if execution sequence missing';
    $worker->current_webui_host('foo');
    $worker->is_busy(1);
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => {id => 42, settings => {}}})
    }
    qr/Refusing to grab job from .* already busy with a job from foo/,
      'ignoring job grab when busy with another web UI';
    $worker->current_webui_host('http://test-host');
    $worker->current_job(OpenQA::Worker::Job->new($worker, $client, {id => 43}));
    $worker->current_job_ids([43]);
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => {id => 42, settings => {}}})
    }
    qr/Refusing to grab job from .* already busy with job\(s\) 43/, 'ignoring job grab when busy with another job';
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOB, job => {id => 43, settings => {}}})
    }
    qr/(?!.*Refusing to grab job).*$/, 'ignoring job grab when already working on that job';
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_LIVELOG_START})
    }
    qr/Ignoring WS message from .* with type livelog_start but no job ID \(currently running 43 for .*\)/,
      'warning about receiving job-specific message without job ID';
    combined_like { $command_handler->handle_command(undef, {type => 'foo'}); }
    qr/Ignoring WS message with unknown type foo.*/, 'ignoring messages of unknown type';
    $worker->current_job(undef);
    $worker->current_job_ids([]);
    $worker->is_busy(0);
    my $rejection = sub { {json => {job_ids => shift, reason => shift, type => 'rejected'}} };
    is_deeply(
        $ws->sent_messages,
        [
            $rejection->([42], 'some error'),
            $rejection->([42], 'some error'),
            $rejection->(['but no settings'], 'the provided job is invalid'),
            $rejection->(['42'], 'job info lacks execution sequence'),
            $rejection->(['42'], 'already busy with a job from foo'),
            $rejection->(['42'], 'already busy with job(s) 43'),
        ],
        'jobs have been rejected in the error cases (when possible), no rejection for job 43'
    ) or diag explain $ws->sent_messages;

    # test setting population
    $command_handler->handle_command(undef, {type => 'info', population => -42});
    is($client->webui_host_population, -42, 'population assigned');

    # test accepting a job
    is($worker->current_job, undef, 'no job accepted so far');
    $command_handler->handle_command(undef,
        {type => WORKER_COMMAND_GRAB_JOB, job => {id => 25, settings => {FOO => 'bar'}}});
    my $accepted_job = $worker->current_job;
    is_deeply($accepted_job->info, {id => 25, settings => {FOO => 'bar'}}, 'job accepted');

    # test live mode related commands
    is($accepted_job->livelog_viewers, 0, 'developer session not started in the first place');
    is($accepted_job->livelog_viewers, 0, 'no livelog viewers in the first place');
    $command_handler->handle_command(undef, {type => WORKER_COMMAND_LIVELOG_START, jobid => 25});
    is($accepted_job->livelog_viewers, 1, 'livelog started');
    $command_handler->handle_command(undef, {type => WORKER_COMMAND_DEVELOPER_SESSION_START, jobid => 25});
    is($accepted_job->developer_session_running, 1, 'developer session running');
    $command_handler->handle_command(undef, {type => WORKER_COMMAND_LIVELOG_STOP, jobid => 25});
    is($accepted_job->livelog_viewers, 0, 'livelog stopped');

    combined_like { $command_handler->handle_command(undef, {type => WORKER_COMMAND_QUIT, jobid => 27}) }
    qr/Ignoring job cancel from http:\/\/test-host because there's no job with ID 27/,
      'ignoring commands for different job';

    # stopping job
    is($accepted_job->status, 'new',
        'since our fake worker does not start the job is is still supposed to be in state "new" so far');
    $command_handler->handle_command(undef, {type => WORKER_COMMAND_QUIT, jobid => 25});
    is($accepted_job->status, 'stopped', 'job has been stopped');

    # test accepting multiple jobs
    $worker->current_job(undef);
    %job_info = (
        sequence => [26, [27, 28]],
        data => {
            26 => {id => 26, settings => {PARENT => 'job'}},
            27 => {id => 27, settings => {CHILD => ' job 1'}},
            28 => {id => 28, settings => {CHILD => 'job 2'}},
        },
    );
    $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOBS, job_info => \%job_info});
    is_deeply($worker->enqueued_job_info,
        \%job_info, 'job info successfully validated and passed to enqueue_jobs_and_accept_first')
      or diag explain $worker->enqueued_job_info;

    # test refusing multiple jobs due because job data is missing
    delete $job_info{data}->{28};
    $worker->enqueued_job_info(undef);
    combined_like {
        $command_handler->handle_command(undef, {type => WORKER_COMMAND_GRAB_JOBS, job_info => \%job_info})
    }
    qr/Refusing to grab job.*: job data for job 28 is missing/, 'ignoring grab job if no valid job info provided';
    is_deeply($worker->enqueued_job_info, undef, 'no jobs enqueued if validation failed')
      or diag explain $worker->enqueued_job_info;

    # test incompatible (so far the worker stops when receiving this message; there are likely better ways to handle it)
    is($worker->is_stopping, 0, 'not already stopping');
    combined_like {
        $command_handler->handle_command(undef, {type => 'incompatible'})
    }
    qr/running a version incompatible with web UI host http:\/\/test-host and therefore stopped/, 'problem is logged';
    is($worker->is_stopping, 1, 'worker is stopping on incompatible message');
};

$client->worker_id(undef);

subtest 'status timer interval' => sub {
    ok((DEFAULT_WORKER_TIMEOUT - MAX_TIMER) >= 20, 'DEFAULT_WORKER_TIMEOUT is bigger than MAX_TIMER at least by 20 s');

    # note: Using fail() instead of ok() or is() here to prevent flooding log.

    my $instance_number = 1;
    my $population = $instance_number;
    do {
        $client->worker->instance_number($instance_number);
        $client->webui_host_population(++$population);
        $client->send_status_interval(undef);
        my $interval = $client->_calculate_status_update_interval;
        next if in_range($interval, 70, 90);
        # uncoverable statement
        fail("timer $interval for instance $instance_number not in range with worker population of $population");
      }
      for $instance_number .. 10;

    my $compare_timer = sub {
        my ($instance1, $instance2, $population) = @_;
        my %intervals;
        for my $instance_number (($instance1, $instance2)) {
            $client->worker->instance_number($instance_number);
            $client->webui_host_population($population);
            $client->send_status_interval(undef);
            $intervals{$instance_number} = $client->_calculate_status_update_interval;
        }
        return undef unless $intervals{$instance1} == $intervals{$instance2};
        # uncoverable statement
        fail("timer between instances $instance1 and $instance2 not different in a population of $population)");
        diag explain \%intervals;    # uncoverable statement
    };

    $instance_number = 25;
    $population = $instance_number;
    for ($instance_number .. 30) {
        $compare_timer->(7, 9, ++$population);
        $compare_timer->(5, 10, $population);
        $compare_timer->(4, $instance_number, $population);
        $compare_timer->(9, 10, $population);
    }

    $instance_number = 205;
    $population = $instance_number;
    for ($instance_number .. 300) {
        $compare_timer->(40, 190, ++$population);
        $compare_timer->(30, 200, $population);
        $compare_timer->(70, 254, $population);
    }

    $population = 1;
    for (1 .. 999) {
        $client->worker->instance_number(int(rand_range(1, $population)));
        $client->webui_host_population(++$population);
        $client->send_status_interval(undef);
        my $interval = $client->_calculate_status_update_interval;
        next if in_range($interval, MIN_TIMER, MAX_TIMER);
        fail("timer not in range with worker population of $population");    # uncoverable statement
    }
};

subtest 'last error' => sub {
    $client->{_last_error} = 'some error';
    $client->add_context_to_last_error('setup');
    is($client->last_error, 'some error on setup', 'context added');

    $client->reset_last_error;
    $client->add_context_to_last_error('setup');
    is($client->last_error, undef, 'add_context_to_last_error does nothing if there is no last error');
};

subtest 'tear down' => sub {
    ok $client->websocket_connection, 'websocket connection exists before tear down';
    $client->register;
    is $client->websocket_connection, undef, 'old websocket connection is gone after re-register';
};

done_testing();
