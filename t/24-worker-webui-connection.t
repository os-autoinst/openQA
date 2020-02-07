#! /usr/bin/perl

# Copyright (C) 2019-2020 SUSE LLC
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

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojolicious;
use Test::Output 'combined_like';
use Test::Fatal;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use OpenQA::App;
use OpenQA::Test::Case;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Worker::CommandHandler;
use OpenQA::Worker::Job;
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD MAX_TIMER MIN_TIMER);
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
        apikey    => 'foo',
        apisecret => 'bar'
    });

my @happened_events;
$client->on(
    status_changed => sub {
        my ($event_client, $event_data) = @_;

        is($event_client,   $client, 'client passed correctly');
        is(ref $event_data, 'HASH',  'event data is a HASH');
        push(
            @happened_events,
            {
                status        => $event_data->{status},
                error_message => $event_data->{error_message},
            });
    });

is($client->status, 'new', 'client in status new');
like(
    exception {
        $client->send;
    },
    qr{attempt to send command to web UI http://test-host with no worker ID.*},
    'registration required',
);

# assign a fake worker to the client
{
    package Test::FakeSettings;
    use Mojo::Base -base;
    has global_settings              => sub { {RETRY_DELAY => 10, RETRY_DELAY_IF_WEBUI_BUSY => 90} };
    has webui_host_specific_settings => sub { {} };
}
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number         => 1;
    has worker_hostname         => 'test_host';
    has current_webui_host      => undef;
    has capabilities            => sub { {fake_capabilities => 1} };
    has stop_current_job_called => 0;
    has is_stopping             => 0;
    has current_error           => undef;
    has current_job             => undef;
    has has_pending_jobs        => 0;
    has settings                => sub { Test::FakeSettings->new; };
    has enqueued_job_info       => undef;
    has skipped_jobs            => sub { {}; };
    sub stop_current_job {
        my ($self, $reason) = @_;
        $self->stop_current_job_called($reason);
    }
    sub status { {fake_status => 1} }
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
    sub skip_job {
        my ($self, $job_id, $reason) = @_;
        $self->skipped_jobs->{$job_id} = $reason;
    }
}
$client->worker(Test::FakeWorker->new);
$client->working_directory('t/');

# mock OpenQA::Worker::Job so it starts/stops the livelog also if the backend isn't running
my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
$job_mock->mock(
    start_livelog => sub {
        my ($self) = @_;
        $self->{_livelog_viewers} = 1;
    });
$job_mock->mock(
    stop_livelog => sub {
        my ($self) = @_;
        $self->{_livelog_viewers} = 0;
    });

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
        post          => 'jobs/500/status',
        json          => {status => 'running'},
        ignore_errors => 1,
        tries         => 1,
        callback      => sub {
            my ($res) = @_;
            is($res, undef, 'undefined result returned in the error case');
            $callback_invoked = 1;
        },
    );
    Mojo::IOLoop->start;
    is($callback_invoked,                        1, 'callback has been invoked');
    is($client->worker->stop_current_job_called, 0, 'not attempted to stop current job');

    # test failing REST API call *not* ignoring errors
    $callback_invoked = 0;
    combined_like(
        sub {
            $client->send(
                post     => 'jobs/500/status',
                json     => {status => 'running'},
                tries    => 1,
                callback => sub {
                    my ($res) = @_;
                    is($res, undef, 'undefined result returned in the error case');
                    $callback_invoked = 1;
                },
            );
            Mojo::IOLoop->start;
        },
        qr/Connection error: Can't connect:.*(remaining tries: 0)/s,
        'error logged',
    );
    is($callback_invoked, 1, 'callback has been invoked');
    is($client->worker->stop_current_job_called,
        0, 'not attempted to stop current job because it is from different web UI');
    $client->worker->current_webui_host('http://test-host');
    $callback_invoked = 0;
    combined_like(
        sub {
            $client->send(
                post     => 'jobs/500/status',
                json     => {status => 'running'},
                tries    => 1,
                callback => sub {
                    my ($res) = @_;
                    is($res, undef, 'undefined result returned in the error case');
                    $callback_invoked = 1;
                },
            );
            Mojo::IOLoop->start;
        },
        qr/Connection error:.*(remaining tries: 0)/s,
        'error logged',
    );

    is($callback_invoked, 1, 'callback has been invoked');
    is($client->worker->stop_current_job_called,
        'api-failure', 'attempted to stop current job with reason "api-failure"');

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
        has res   => undef;
    }
    {
        package Test::FakeUserAgent;
        use Mojo::Base -base;
        has fake_error  => undef;
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
    my $fake_ua    = Test::FakeUserAgent->new(fake_error => $fake_error);
    my $default_ua = $client->ua;
    $client->ua($fake_ua);

    # mock retry delay so tests don't take forever
    my $web_ui_connection_mock                = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
    my $web_ui_supposed_to_be_considered_busy = 1;
    my $retry_delay_invoked                   = 0;
    $web_ui_connection_mock->mock(
        _retry_delay => sub {
            my ($self, $is_webui_busy) = @_;
            is($is_webui_busy, $web_ui_supposed_to_be_considered_busy, 'retry delay applied accordingly');
            $retry_delay_invoked += 1;
            return 0;
        });

    # define arguments for send call
    my $callback_invoked = 0;
    my @send_args        = (
        post     => 'jobs/500/status',
        json     => {status => 'running'},
        callback => sub {
            my ($res) = @_;
            is($res, undef, 'undefined result returned in the error case');
            $callback_invoked += 1;
        },
    );

    subtest 'retry after timeout' => sub {
        combined_like(
            sub {
                $client->send(@send_args);
                Mojo::IOLoop->start;
            },
qr/Connection error: some timeout \(remaining tries: 2\).*Connection error: some timeout \(remaining tries: 1\).*Connection error: some timeout \(remaining tries: 0\)/s,
            'attempts logged',
        );
        is($fake_ua->start_count, 3, 'tried 3 times');
        is($callback_invoked,     1, 'callback invoked exactly one time');

        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        $fake_error->{code} = 502;
        combined_like(
            sub {
                $client->send(@send_args);
                Mojo::IOLoop->start;
            },
qr/502 response: some timeout \(remaining tries: 2\).*502 response: some timeout \(remaining tries: 1\).*502 response: some timeout \(remaining tries: 0\)/s,
            'attempts logged',
        );
        is($fake_ua->start_count, 3, 'tried 3 times');
        is($callback_invoked,     1, 'callback invoked exactly one time');
        is($retry_delay_invoked,  2, 'retry delay queried');
    };

    subtest 'retry after unknown API error' => sub {
        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        $fake_error->{message}                 = 'some error';
        $fake_error->{code}                    = 500;
        $web_ui_supposed_to_be_considered_busy = undef;
        combined_like(
            sub {
                $client->send(@send_args, tries => 2);
                Mojo::IOLoop->start;
            },
            qr/500 response: some error \(remaining tries: 1\).*500 response: some error \(remaining tries: 0\)/s,
            'attempts logged',
        );
        is($fake_ua->start_count, 2, 'tried 2 times');
        is($callback_invoked,     1, 'callback invoked exactly one time');
        is($retry_delay_invoked,  1, 'retry delay queried');
    };

    subtest 'no retry after 404' => sub {
        $callback_invoked = $retry_delay_invoked = 0;
        $fake_ua->start_count(0);
        $fake_error->{message} = 'Not found';
        $fake_error->{code}    = 404;
        combined_like(
            sub {
                $client->send(@send_args, tries => 3);
                Mojo::IOLoop->start;
            },
            qr/404 response: Not found \(remaining tries: 0\)/,
            '404 logged',
        );
        is($fake_ua->start_count, 1, 'tried 1 time');
        is($callback_invoked,     1, 'callback invoked exactly one time');
        is($retry_delay_invoked,  0, 'retry delay not queried');
    };

    subtest 'no retry if ignoring errors' => sub {
        $callback_invoked = 0;
        $fake_ua->start_count(0);
        $client->send(@send_args, tries => 3, ignore_errors => 1);
        Mojo::IOLoop->start;
        is($fake_ua->start_count, 1, 'no retry attempts');
        is($callback_invoked,     1, 'callback invoked exactly one time');
        is($retry_delay_invoked,  0, 'retry delay not queried');
    };

    $client->ua($default_ua);
};

subtest 'retry delay configurable' => sub {
    is($client->_retry_delay(0), 10, 'default delay used from global settings');
    is($client->_retry_delay(1), 90, '"busy" delay used from global settings');

    $client->worker->settings->webui_host_specific_settings->{$client->webui_host} = {
        RETRY_DELAY               => 30,
        RETRY_DELAY_IF_WEBUI_BUSY => 120,
    };
    is($client->_retry_delay(0), 30,  'default delay used from host-specific settings');
    is($client->_retry_delay(1), 120, '"busy" delay used from host-sepcific settings');
};

subtest 'send status' => sub {
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    $client->websocket_connection($ws);
    $client->send_status_interval(0.5);
    $client->send_status();
    is_deeply($ws->sent_messages, [{json => {fake_status => 1}}], 'status sent')
      or diag explain $ws->sent_messages;
};

subtest 'quit' => sub {
    my $ws              = OpenQA::Test::FakeWebSocketTransaction->new;
    my $callback_called = 0;
    my $callback        = sub { $callback_called = 1; };

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

subtest 'command handler' => sub {
    my $command_handler = OpenQA::Worker::CommandHandler->new($client);
    my $worker          = $client->worker;

    # test at least some of the error cases
    combined_like(
        sub { $command_handler->handle_command(undef, {}); },
        qr/Ignoring WS message without type from http:\/\/test-host.*/,
        'ignoring non-result message without type',
    );
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'livelog_stop', jobid => 1}); },
qr/Ignoring WS message from http:\/\/test-host with type livelog_stop and job ID 1 \(currently not executing a job\).*/,
        'ignoring job-specific message when no job running',
    );
    $worker->current_error('some error');
    $app->log->level('debug');
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'grab_job'}); },
        qr/Refusing 'grab_job', we are currently unable to do any work: some error/,
        'ignoring grab_job while in error-state',
    );
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'grab_jobs'}); },
        qr/Refusing 'grab_job', we are currently unable to do any work: some error/,
        'ignoring grab_jobs while in error-state',
    );
    is($worker->current_job, undef, 'no job has been accepted while in error-state');

    $worker->current_error(undef);
    $worker->is_stopping(1);
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'grab_job'}); },
        qr/Refusing 'grab_job', the worker is currently stopping/,
        'ignoring grab_job while stopping',
    );

    $app->log->level('info');
    $worker->is_stopping(0);

    combined_like(
        sub {
            $command_handler->handle_command(
                undef,
                {
                    type => 'grab_job',
                    job  => {id => 'but no settings'}});
        },
        qr/Refusing to grab job.*because the provided job is invalid.*/,
        'ignoring grab job if no valid job info provided',
    );
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'foo'}); },
        qr/Ignoring WS message with unknown type foo.*/,
        'ignoring messages of unknown type',
    );

    # test setting population
    $command_handler->handle_command(undef, {type => 'info', population => -42});
    is($client->webui_host_population, -42, 'population assigned');

    # test accepting a job
    is($worker->current_job, undef, 'no job accepted so far');
    $command_handler->handle_command(
        undef,
        {
            type => 'grab_job',
            job  => {id => 25, settings => {FOO => 'bar'}}});
    my $accepted_job = $worker->current_job;
    is_deeply($accepted_job->info, {id => 25, settings => {FOO => 'bar'}}, 'job accepted');

    # test live mode related commands
    is($accepted_job->livelog_viewers, 0, 'developer session not started in the first place');
    is($accepted_job->livelog_viewers, 0, 'no livelog viewers in the first place');
    $command_handler->handle_command(undef, {type => 'livelog_start', jobid => 25});
    is($accepted_job->livelog_viewers, 1, 'livelog started');
    $command_handler->handle_command(undef, {type => 'developer_session_start', jobid => 25});
    is($accepted_job->developer_session_running, 1, 'developer session running');
    $command_handler->handle_command(undef, {type => 'livelog_stop', jobid => 25});
    is($accepted_job->livelog_viewers, 0, 'livelog stopped');

    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'quit', jobid => 27}); },
        qr/Ignoring job cancel from http:\/\/test-host because there's no job with ID 27/,
        'ignoring commands for different job',
    );

    # stopping job
    is($accepted_job->status, 'new',
        'since our fake worker does not start the job is is still supposed to be in state "new" so far');
    $command_handler->handle_command(undef, {type => 'quit', jobid => 25});
    is($accepted_job->status, 'stopped', 'job has been stopped');


    # test accepting multiple jobs
    $worker->current_job(undef);
    my %job_info = (
        sequence => [26, [27, 28]],
        data     => {
            26 => {id => 26, settings => {PARENT => 'job'}},
            27 => {id => 27, settings => {CHILD  => ' job 1'}},
            28 => {id => 28, settings => {CHILD  => 'job 2'}},
        },
    );
    $command_handler->handle_command(undef, {type => 'grab_jobs', job_info => \%job_info});
    is_deeply($worker->enqueued_job_info,
        \%job_info, 'job info successfully validated and passed to enqueue_jobs_and_accept_first')
      or diag explain $worker->enqueued_job_info;

    # test refusing multiple jobs due because job data is missing
    delete $job_info{data}->{28};
    $worker->enqueued_job_info(undef);
    combined_like(
        sub {
            $command_handler->handle_command(undef, {type => 'grab_jobs', job_info => \%job_info});
        },
        qr/Refusing to grab job.*because job data for job 28 is missing/,
        'ignoring grab job if no valid job info provided',
    );
    is_deeply($worker->enqueued_job_info, undef, 'no jobs enqueued if validation failed')
      or diag explain $worker->enqueued_job_info;
};

$client->worker_id(undef);
# FIXME: test a real connection

subtest 'status timer interval' => sub {
    ok((WORKERS_CHECKER_THRESHOLD - MAX_TIMER) >= 20,
        'WORKERS_CHECKER_THRESHOLD is bigger than MAX_TIMER at least by 20s');

    # note: Using fail() instead of ok() or is() here to prevent flooding log.

    my $instance_number = 1;
    my $population      = $instance_number;
    do {
        $client->worker->instance_number($instance_number);
        $client->webui_host_population(++$population);
        $client->send_status_interval(undef);
        my $interval = $client->_calculate_status_update_interval;
        next if in_range($interval, 70, 90);
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
        fail("timer between instances $instance1 and $instance2 not different in a population of $population)");
        diag explain \%intervals;
    };

    $instance_number = 25;
    $population      = $instance_number;
    for ($instance_number .. 30) {
        $compare_timer->(7, 9,                ++$population);
        $compare_timer->(5, 10,               $population);
        $compare_timer->(4, $instance_number, $population);
        $compare_timer->(9, 10,               $population);
    }

    $instance_number = 205;
    $population      = $instance_number;
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
        fail("timer not in range with worker population of $population");
    }
};

done_testing();
