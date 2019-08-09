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

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use Mojo::Base -strict;
use Mojo::File qw(tempdir path);
use Mojolicious;
use Test::Fatal;
use Test::Output 'combined_like';
use Test::More;
use Test::MockModule;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Worker;
use OpenQA::Worker::Job;
use OpenQA::Worker::Settings;
use OpenQA::Worker::Engines::isotovideo;

# use Mojo::Log and be sure to log debug messages
my $app = $OpenQA::Utils::app = Mojolicious->new;
$app->log->level('debug');

# define a minimal fake worker and fake client
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
        $args{callback}->({}) if $args{callback};
    }
    sub send_status { push(@{shift->sent_messages}, @_); }
    sub register { shift->register_called(1); }
}
{
    package Test::FakeProcess;
    use Mojo::Base -base;
    has pid        => 1;
    has errored    => 0;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}

# define helper to run the IO loop until the next result upload has been concluded
sub wait_until_upload_concluded {
    my ($job) = @_;

    $job->once(uploading_results_concluded => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
}

# mock isotovideo 'engine' here - we don't actually want to start it in that test
my $engine_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
$engine_mock->mock(
    engine_workit => sub {
        note('pretending isotovideo startup error');
        return {error => 'some error'};
    });

# log which files and assets would have been uploaded
my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
my @uploaded_files;
my $upload_result = 1;
$job_mock->mock(_upload_log_file => sub { shift; push(@uploaded_files, [@_]); return $upload_result; });
my @uploaded_assets;
$job_mock->mock(_upload_asset => sub { shift; push(@uploaded_assets, [@_]); return $upload_result; });

# setup a job with fake worker and client
my $isotovideo     = Test::FakeProcess->new;
my $worker         = Test::FakeWorker->new;
my $client         = Test::FakeClient->new;
my $job            = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => 'url'});
my $pool_directory = tempdir('poolXXXX');
$worker->pool_directory($pool_directory);
$client->ua->connect_timeout(0.1);

# handle/log events
my @happended_events;
my $handle_job_event = sub {
    my ($event_client, $event_data) = @_;

    is($event_client,   $job,   'job passed correctly');
    is(ref $event_data, 'HASH', 'event data is a HASH');
    my $status = $event_data->{status};
    my %event  = (status => $status,);
    $event{error_message} = $event_data->{error_message} if $event_data->{error_message};
    push(@happended_events, \%event);
    Mojo::IOLoop->stop if $status eq 'stopped';
};
$job->on(status_changed => $handle_job_event);

# start the actual testing of going though the job live-cycle (in particular a setup failure and a
# manually stopped job)

# accept the job
$job->accept();
is($job->status, 'accepted', 'job is now accepted');

# simulate that the websocket connection is interrupted
$job->client->websocket_connection->emit_finish;
is($job->status, 'accepted',
    'ws disconnects are not considered fatal one the job is accepted so it is still in accepted state');

# simulate that the websocket connection is interrupted before we can tell the web UI that we want to work on it
$job->{_status} = 'accepting';
$job->client->websocket_connection->emit_finish;
is($job->status, 'stopped', 'job is abandoned if unable to confirm to the web UI that we are working on it');

# test that it is not possible to start the job in that state
like(
    exception { $job->start(); },
    qr/attempt to start job which is not accepted/,
    'starting job prevented unless accepted',
);

# pretend that the job has been accepted after all
$job->{_status} = 'accepted';

# put some 'old' logs into the pool directory to verify whether those are cleaned up
$pool_directory->child('autoinst-log.txt')->spurt('Hello Mojo!');

# put a fake test_order.json into the pool directory
my $testresults_directory = path($pool_directory, 'testresults');
$testresults_directory->make_path;
$testresults_directory->child('test_order.json')->spurt('[]');

# try to start job
combined_like(sub { $job->start(); }, qr/Unable to setup job 1\: some error/, 'error logged');
Mojo::IOLoop->start unless $job->status eq 'stopped';
is($job->status,      'stopped',    'job is stopped due to the mocked error');
is($job->setup_error, 'some error', 'setup error recorded');

# verify old logs being cleaned up and worker-log.txt being created
ok(!-e $pool_directory->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted');
ok(-e $pool_directory->child('worker-log.txt'),    'worker log is there');

# pretend that the failure didn't happen to be able to continue testing
# note: The actual worker always creates a new OpenQA::Worker::Job object.
$job->{_status} = 'accepted';

# change the job ID before starting again to better distinguish the resulting messages
$job->{_id} = 2;

# try to start job again pretending isotovideo could actually be spawned
$engine_mock->mock(
    engine_workit => sub {
        note('pretending to run isotovideo');
        return {child => $isotovideo};
    });
combined_like(
    sub {
        $job->start();
        wait_until_upload_concluded($job);
    },
    qr/isotovideo has been started/,
    'isotovideo startup logged'
);
is($job->is_uploading_results, 0,         'uploading results concluded');
is($job->status,               'running', 'job is running now');
ok($job->{_upload_results_timer}, 'timer for uploading results assigned');
ok($job->{_timeout_timer},        'timer for timeout assigned');

# perform another result upload triggered via start_livelog
# also assume that a developer mode sesssion is running
$job->developer_session_running(1);
combined_like(sub { $job->start_livelog; }, qr/Starting livelog/, 'start of livelog logged');
is($job->livelog_viewers, 1, 'has now one livelog viewer');
wait_until_upload_concluded($job);
combined_like(sub { $job->stop_livelog; }, qr/Stopping livelog/, 'stopping of livelog logged');
is($job->livelog_viewers, 0, 'no livelog viewers anymore');

# stop job again
is($isotovideo->is_running, 1, 'not attempted to stop fake isotovideo so far');
combined_like(
    sub {
        $job->stop('done');
        wait_until_upload_concluded($job);
    },
    qr/Result\: done.*Uploading autoinst-log\.txt/s,
    'result and uploading logged'
);
Mojo::IOLoop->start unless $job->status eq 'stopped';
is($job->status,            'stopped', 'job is stopped now');
is($isotovideo->is_running, 0,         'isotovideo stopped');

is($job->{_upload_results_timer}, undef, 'timer for uploading results has been cleaned up');
is($job->{_timeout_timer},        undef, 'timer for timeout has been cleaned up');

# verify messages sent via REST API and websocket connection during the job live-cycle
# note: This can also be seen as an example for other worker implementations.
is_deeply(
    $client->sent_messages,
    [
        # the first $job->start(); results simulates a setup error
        # hence the job is stopped again immediately and uploading results starts directly
        {
            json => {
                status => {
                    uploading => 1,
                    worker_id => 1
                }
            },
            path => 'jobs/1/status'
        },
        # the final status upload also happens in the error case
        {
            json => {
                status => {
                    backend               => undef,
                    cmd_srv_url           => 'url',
                    result                => {},
                    test_execution_paused => 0,
                    test_order            => [],
                    worker_hostname       => undef,
                    worker_id             => 1
                }
            },
            path => 'jobs/1/status'
        },
        # the job is marked as done
        {
            json => undef,
            path => 'jobs/1/set_done'
        },
        # initial status post done after the second $job->start();
        {
            path => 'jobs/2/status',
            json => {
                status => {
                    cmd_srv_url           => 'url',
                    test_execution_paused => 0,
                    worker_hostname       => undef,
                    worker_id             => 1
                }}
        },
        # subsequent status posts
        {
            path => 'jobs/2/status',
            json => {
                status => {
                    cmd_srv_url           => 'url',
                    log                   => {},
                    serial_log            => {},
                    serial_terminal       => {},
                    test_execution_paused => 0,
                    worker_hostname       => undef,
                    worker_id             => 1
                }}
        },
        # upload progress posted because we've set $job->developer_session_running(1);
        {
            path => '/liveviewhandler/api/v1/jobs/2/upload_progress',
            json => {
                outstanding_files           => 0,
                outstanding_images          => 0,
                upload_up_to                => undef,
                upload_up_to_current_module => undef,
            },
        },
        {
            path => 'jobs/2/status',
            json => {
                status => {
                    cmd_srv_url           => 'url',
                    log                   => {},
                    serial_log            => {},
                    serial_terminal       => {},
                    test_execution_paused => 0,
                    worker_hostname       => undef,
                    worker_id             => 1
                }}
        },
        # no further upload progress posted because the upload progress has not changed
        # status set to uploading due to $job->stop;
        {
            path => 'jobs/2/status',
            json => {
                status => {
                    uploading => 1,
                    worker_id => 1,
                }
            },
        },
        # no further upload progress posted during final upload
        # just the usual status update
        {
            path => 'jobs/2/status',
            json => {
                status => {
                    backend               => undef,
                    cmd_srv_url           => 'url',
                    result                => {},
                    test_execution_paused => 0,
                    test_order            => [],
                    worker_hostname       => undef,
                    worker_id             => 1
                }
            },
        },
        # set_done called in the end
        {
            path => 'jobs/2/set_done',
            json => undef,
        },
    ],
    'expected REST-API calls happened'
) or diag explain $client->sent_messages;
is_deeply(
    $client->websocket_connection->sent_messages,
    [
        {
            json => {
                jobid => 1,
                type  => 'accepted',
            }
        },
        # note: In this test we only excercise accepting the job once. Hence there
        #       is no message for the 2nd job.
    ],
    'job accepted via ws connection'
) or diag explain $client->websocket_connection->sent_messages;

# verify that all status events for the job live-cycle have been emitted
is_deeply(
    \@happended_events,
    [
        # live-cycle of job 1
        {status => 'accepting'},
        {status => 'accepted'},
        # stopped due to pretended failure to confirm job; we only recover here by also pretending
        # it worked after all (for the sake of this test)
        {status => 'stopped'},
        {status => 'setup'},
        {status => 'stopping'},
        {status => 'stopped'},
        # live-cycle of job 2
        {status => 'setup'},
        {status => 'running'},
        {status => 'stopping'},
        {status => 'stopped'},
    ],
    'status changes emitted'
) or diag explain \@happended_events;

# verify that files and assets would have been uploaded
# TODO: actually provide some assets and have some variety between the jobs
is_deeply(
    \@uploaded_files,
    [
        # files for job 1
        [
            {
                file => {
                    file     => "$pool_directory/autoinst-log.txt",
                    filename => 'autoinst-log.txt'
                }
            },
        ],
        # files for job 2 (no changes compared to job 1)
        [
            {
                file => {
                    file     => "$pool_directory/autoinst-log.txt",
                    filename => 'autoinst-log.txt'
                }
            },
        ]
    ],
    'would have uploaded logs'
) or diag explain \@uploaded_files;
is_deeply(\@uploaded_assets, [], 'no assets uploaded because this test so far has none')
  or diag explain \@uploaded_assets;

# reset fake isotovideo and 'test results'
$isotovideo->is_running(1);
@happended_events = ();
@uploaded_files   = ();
@uploaded_assets  = ();
$client->sent_messages([]);
$client->websocket_connection->sent_messages([]);

# exercise another job live-cycle simulating an API failure
subtest 'handling API failures' => sub {
    # create and accept new job
    $job = OpenQA::Worker::Job->new($worker, $client, {id => 3, URL => 'url'});
    $job->on(status_changed => $handle_job_event);
    $job->accept;

    combined_like(
        sub {
            $job->start();
            wait_until_upload_concluded($job);
        },
        qr/isotovideo has been started/,
        'isotovideo startup logged'
    );

    is($client->register_called, 0, 'no re-registration attempted so far');

    combined_like(
        sub {
            $job->stop('api-failure');
            wait_until_upload_concluded($job);
        },
        qr/Result: api-failure/,
        'job stopped after an API failure'
    );

    is($client->register_called, 1, 'worker tried to register itself again after an API failure');

    # verify that all status events for the job live-cycle have been emitted
    is_deeply(
        \@happended_events,
        [map { {status => $_} } (qw(accepting accepted setup running stopping stopped))],
        'status changes emitted'
    ) or diag explain \@happended_events;

    # verify messages sent via REST API and websocket connection during the job live-cycle
    # note: This can also be seen as an example for other worker implementations.
    is($client->sent_messages->[-1]->{path}, 'jobs/3/set_done', 'set_done is still attempted to be called')
      or diag explain $client->sent_messages;

    # verify that the upload has been skipped
    is_deeply(\@uploaded_files, [], 'file upload skipped after API failure')
      or diag explain \@uploaded_files;
    is_deeply(\@uploaded_assets, [], 'asset upload skipped after API failure')
      or diag explain \@uploaded_assets;
};

# reset state
@happended_events = ();
$isotovideo->is_running(1);
$client->register_called(0);

# exercise another job live-cycle simulating an upload failure
subtest 'handle upload failure' => sub {
    # assume all uploads fail (set this temporarily to 1 to "test the test" which should fail then)
    $upload_result = 0;

    # create and accept new job
    $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => 'url'});
    $job->on(status_changed => $handle_job_event);
    $job->accept;

    combined_like(
        sub {
            $job->start();
            wait_until_upload_concluded($job);
        },
        qr/isotovideo has been started/,
        'isotovideo startup logged'
    );

    # assume isotovideo generated some logs
    my $log_dir = $pool_directory->child('ulogs');
    $log_dir->make_path;
    $log_dir->child('foo')->spurt('some log');
    $log_dir->child('bar')->spurt('another log');

    # assume isotovideo generated some assets
    my $asset_dir = $pool_directory->child('assets_public');
    $asset_dir->make_path;
    $asset_dir->child('hdd1.qcow')->spurt('data');
    $asset_dir->child('hdd2.qcow')->spurt('more data');

    combined_like(
        sub {
            $job->stop('done');
            wait_until_upload_concluded($job);
        },
        qr/Result: done/,
        'job stopped after done'
    );

    is($client->register_called, 1, 'worker tried to register itself again after an upload failure');

    # verify that all status events for the job live-cycle have been emitted
    is_deeply(
        \@happended_events,
        [map { {status => $_} } (qw(accepting accepted setup running stopping stopped))],
        'status changes emitted'
    ) or diag explain \@happended_events;

    # verify messages sent via REST API and websocket connection during the job live-cycle
    # note: This can also be seen as an example for other worker implementations.
    is($client->sent_messages->[-1]->{path}, 'jobs/4/set_done', 'set_done is still attempted to be called')
      or diag explain $client->sent_messages;

    # verify that the upload has been skipped
    my $ok = 1;
    is(scalar @uploaded_files, 2, 'only 2 files uploaded; stopped after first failure') or $ok = 0;
    my $log_name = $uploaded_files[0]->[0]->{file}->{filename};
    ok($log_name eq 'bar' || $log_name eq 'foo', 'one of the logs attempted to be uploaded') or $ok = 0;
    is_deeply(
        $uploaded_files[1],
        [
            {
                file => {
                    file     => "$pool_directory/autoinst-log.txt",
                    filename => 'autoinst-log.txt'
                }
            },
        ],
        'uploading autoinst log tried even though other logs failed'
    ) or $ok = 0;
    diag explain \@uploaded_files unless $ok;
    is_deeply(\@uploaded_assets, [], 'asset upload skipped after previous upload failure')
      or diag explain \@uploaded_assets;
};

done_testing();
