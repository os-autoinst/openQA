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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Fatal;
use Test::Output 'combined_like';
use Test::MockModule;
use Mojo::File qw(path tempdir);
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use OpenQA::Worker::Job;
use OpenQA::Worker::Settings;
use OpenQA::Test::FakeWebSocketTransaction;

sub wait_until_job_stopped {
    my $job = shift;

    # Do not wait forever in case of problems
    my $error;
    my $timer = Mojo::IOLoop->timer(
        10 => sub {
            $error = 'Job was not stopped after 10 seconds';
            Mojo::IOLoop->stop;
        });

    # Watch the status event for changes
    my $cb = $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            my $status = $event_data->{status};
            Mojo::IOLoop->stop if $status eq 'stopped';
        });
    Mojo::IOLoop->start;
    $job->unsubscribe(status_changed => $cb);
    Mojo::IOLoop->remove($timer);

    return $error;
}

# Fake worker, client and engine
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number => 1;
    has settings        => sub { OpenQA::Worker::Settings->new(1, {}) };
    has pool_directory  => undef;
}
{
    package Test::FakeClient;
    use Mojo::Base -base;
    has worker_id            => 1;
    has webui_host           => 'not relevant here';
    has working_directory    => 'not relevant here';
    has testpool_server      => 'not relevant here';
    has sent_messages        => sub { [] };
    has websocket_connection => sub { OpenQA::Test::FakeWebSocketTransaction->new };
    has ua                   => sub { Mojo::UserAgent->new };
    has url                  => sub { Mojo::URL->new };
    has register_called      => 0;
    sub send {
        my ($self, $method, $path, %args) = @_;
        push(@{shift->sent_messages}, {path => $path, json => $args{json}});
        Mojo::IOLoop->next_tick(sub { $args{callback}->({}) }) if $args{callback};
    }
    sub send_status { push(@{shift->sent_messages}, @_) }
    sub register { shift->register_called(1) }
}
{
    package Test::FakeEngine;
    use Mojo::Base -base;
    has pid        => 1;
    has errored    => 0;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}

my $isotovideo     = Test::FakeEngine->new;
my $worker         = Test::FakeWorker->new;
my $pool_directory = tempdir('poolXXXX');
$worker->pool_directory($pool_directory);
my $client = Test::FakeClient->new;
$client->ua->connect_timeout(0.1);

# Mock isotovideo engine (simulate startup failure)
my $engine_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
$engine_mock->mock(
    engine_workit => sub {
        note 'pretending isotovideo startup error';
        return {error => 'this is not a real isotovideo'};
    });

# Mock isotovideo REST API
my $api_mock = Test::MockModule->new('OpenQA::Worker::Isotovideo::Client');
$api_mock->mock(
    status => sub {
        my ($isotovideo_client, $callback) = @_;
        Mojo::IOLoop->next_tick(sub { $callback->($isotovideo_client, {}) });
    });

subtest 'Interrupted WebSocket connection' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => 'url'});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    $job->client->websocket_connection->emit_finish;
    is $job->status, 'accepted',
      'ws disconnects are not considered fatal one the job is accepted so it is still in accepted state';
};

subtest 'Interrupted WebSocket connection (before we can tell the WebUI that we want to work on it)' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 2, URL => 'url'});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    $job->_set_status(accepting => {});
    $job->client->websocket_connection->emit_finish;
    is $job->status, 'stopped', 'job is abandoned if unable to confirm to the web UI that we are working on it';
    like(
        exception { $job->start },
        qr/attempt to start job which is not accepted/,
        'starting job prevented unless accepted'
    );
};

subtest 'Job without id' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => undef, URL => 'url'});
    like(
        exception { $job->start },
        qr/attempt to start job without ID and job info/,
        'starting job without id prevented'
    );
};

subtest 'Clean up pool directory' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 3, URL => 'url'});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';

    # Put some 'old' logs into the pool directory to verify whether those are cleaned up
    $pool_directory->child('autoinst-log.txt')->spurt('Hello Mojo!');

    # Put a fake test_order.json into the pool directory
    my $testresults_directory = path($pool_directory, 'testresults');
    $testresults_directory->make_path;
    $testresults_directory->child('test_order.json')->spurt('[]');

    # Try to start job
    combined_like sub { $job->start }, qr/Unable to setup job 3: this is not a real isotovideo/, 'error logged';
    is wait_until_job_stopped($job), undef, 'no error';
    is $job->status, 'stopped', 'job is stopped due to the mocked error';
    is $job->setup_error, 'this is not a real isotovideo', 'setup error recorded';

    # verify old logs being cleaned up and worker-log.txt being created
    ok !-e $pool_directory->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted';
    ok -e $pool_directory->child('worker-log.txt'),    'worker log is there';
};

# Mock isotovideo engine (simulate successful startup)
$engine_mock->mock(
    engine_workit => sub {
        note 'pretending to run isotovideo';
        return {child => $isotovideo};
    });

subtest 'Successful startup' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => 'url'});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    combined_like(
        sub {
            $job->start();
        },
        qr/isotovideo has been started/,
        'isotovideo startup logged'
    );
    #is wait_until_job_stopped($job), undef, 'no error';
    #is $job->status,               'stopped', 'job is stopped successfully';
    #is $job->is_uploading_results, 0,         'uploading results concluded';
    # TO BE CONTINUED!
};

done_testing();
