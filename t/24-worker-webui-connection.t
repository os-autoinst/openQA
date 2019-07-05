#! /usr/bin/perl

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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Mojo::IOLoop;
use Test::Output 'combined_like';
use Test::Fatal;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use OpenQA::Test::Case;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Worker::CommandHandler;
use OpenQA::Worker::Job;
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD MAX_TIMER MIN_TIMER);
use OpenQA::Utils qw(in_range rand_range);

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

my @happended_events;
$client->on(
    status_changed => sub {
        my ($event_client, $event_data) = @_;

        is($event_client,   $client, 'client passed correctly');
        is(ref $event_data, 'HASH',  'event data is a HASH');
        push(
            @happended_events,
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
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number         => 1;
    has worker_hostname         => 'test_host';
    has current_webui_host      => undef;
    has capabilities            => sub { {fake_capabilities => 1} };
    has stop_current_job_called => 0;
    has current_error           => undef;
    has current_job             => undef;
    sub stop_current_job { shift->stop_current_job_called(1); }
    sub status           { {fake_status => 1} }
    sub accept_job {
        my ($self, $client, $job_info) = @_;
        $self->current_job(OpenQA::Worker::Job->new($self, $client, $job_info));
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
        qr/.*\[ERROR\] Connection error:.*(remaining tries: 0).*/s,
        'error logged',
    );

    is($callback_invoked,                        1, 'callback has been invoked');
    is($client->worker->stop_current_job_called, 1, 'attempted to stop current job');

    is_deeply(
        \@happended_events,
        [
            {
                status        => 'registering',
                error_message => undef,
            },
            {
                status        => 'failed',
                error_message => 'Unable to connect to host http://test-host',
            }
        ],
        'events emitted'
    ) or diag explain \@happended_events;
};

subtest 'send status' => sub {
    my $ws = OpenQA::Test::FakeWebSocketTransaction->new;
    $client->websocket_connection($ws);
    $client->send_status_interval(0.5);
    $client->send_status();
    is_deeply($ws->sent_messages, [{json => {fake_status => 1}}], 'status sent')
      or diag explain $ws->sent_messages;
};

subtest 'command handler' => sub {
    my $command_handler = OpenQA::Worker::CommandHandler->new($client);

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
    $client->worker->current_error('some error');
    combined_like(
        sub { $command_handler->handle_command(undef, {type => 'grab_job'}); },
        qr/Refusing 'grab_job', we are currently unable to do any work: some error/,
        'ignoring grab job while in error-state',
    );
    $client->worker->current_error(undef);
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
    is($client->worker->current_job, undef, 'no job accepted so far');
    $command_handler->handle_command(
        undef,
        {
            type => 'grab_job',
            job  => {id => 25, settings => {FOO => 'bar'}}});
    my $accepted_job = $client->worker->current_job;
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
        qr/Ignoring WS message from http:\/\/test-host for job 27 because that job is not running \(running 25*/,
        'ignoring commands for different job',
    );

    # stopping job
    is($accepted_job->status, 'new',
        'since our fake worker does not start the job is is still supposed to be in state "new" so far');
    $command_handler->handle_command(undef, {type => 'quit', jobid => 25});
    is($accepted_job->status, 'stopped', 'job has been stopped');
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
