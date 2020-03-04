#!/usr/bin/env perl

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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Fatal;
use Test::Output 'combined_like';
use Test::MockModule;
use Mojo::File qw(path tempdir);
use Mojo::JSON 'encode_json';
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use OpenQA::Worker::Job;
use OpenQA::Worker::Settings;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Utils 'shared_hash';

sub wait_until_job_status_ok {
    my ($job, $status) = @_;

    # Do not wait forever in case of problems
    my $error;
    my $timer = Mojo::IOLoop->timer(
        15 => sub {
            $error = 'Job was not stopped after 15 seconds';
            Mojo::IOLoop->stop;
        });

    # Watch the status event for changes
    my $cb = $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            my $new = $event_data->{status};
            note "worker status change: $new";
            Mojo::IOLoop->stop if $new eq $status;
        });
    Mojo::IOLoop->start;
    $job->unsubscribe(status_changed => $cb);
    Mojo::IOLoop->remove($timer);

    # Show caller perspective for failures
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is $error, undef, 'no wait_until_job_status_ok error';
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
    has last_error           => undef;
    has fail_job_duplication => 0;
    sub send {
        my ($self, $method, $path, %args) = @_;
        my $params                = $args{params};
        my %relevant_message_data = (path => $path, json => $args{json});
        for my $relevant_params (qw(result reason)) {
            next unless $params->{$relevant_params};
            $relevant_message_data{$relevant_params} = $params->{$relevant_params};
        }
        push(@{shift->sent_messages}, \%relevant_message_data);
        if ($self->fail_job_duplication && $path =~ qr/.*\/duplicate/) {
            $self->last_error('fake API error');
            return Mojo::IOLoop->next_tick(sub { $args{callback}->(0) });
        }
        Mojo::IOLoop->next_tick(sub { $args{callback}->({}) }) if $args{callback};
    }
    sub reset_last_error { shift->last_error(undef) }
    sub send_status      { push(@{shift->sent_messages}, @_) }
    sub register         { shift->register_called(1) }
    sub add_context_to_last_error {
        my ($self, $context) = @_;
        $self->last_error($self->last_error . " on $context");
    }
}
{
    package Test::FakeEngine;
    use Mojo::Base -base;
    has pid        => 1;
    has errored    => 0;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}

my $isotovideo            = Test::FakeEngine->new;
my $worker                = Test::FakeWorker->new;
my $pool_directory        = tempdir('poolXXXX');
my $testresults_directory = $pool_directory->child('testresults')->make_path;
$testresults_directory->child('test_order.json')->spurt('[]');
$worker->pool_directory($pool_directory);
my $client = Test::FakeClient->new;
$client->ua->connect_timeout(0.1);
my $engine_url = '127.0.0.1:' . Mojo::IOLoop::Server->generate_port;

# Define a function to get the usually expected status updates
sub usual_status_updates {
    my (%args) = @_;
    my $job_id = $args{job_id};

    my @expected_api_calls;
    push(
        @expected_api_calls,
        {
            path => "jobs/$job_id/status",
            json => {
                status => {
                    uploading => 1,
                    worker_id => 1
                }
            },
        });
    push(
        @expected_api_calls,
        {
            path => "jobs/$job_id/duplicate",
            json => undef,
        }) if $args{duplicate};
    push(
        @expected_api_calls,
        {
            path => "jobs/$job_id/status",
            json => {
                status => {
                    cmd_srv_url           => $engine_url,
                    result                => {},
                    test_execution_paused => 0,
                    test_order            => [],
                    worker_hostname       => undef,
                    worker_id             => 1
                }
            },
        }) unless $args{no_overall_status};
    return @expected_api_calls;
}

# Mock isotovideo engine (simulate startup failure)
my $engine_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
$engine_mock->mock(
    engine_workit => sub {
        note 'pretending isotovideo startup error';
        return {error => 'this is not a real isotovideo'};
    });

# Mock log file and asset uploads to collect diagnostics
my $job_mock            = Test::MockModule->new('OpenQA::Worker::Job');
my $default_shared_hash = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
shared_hash $default_shared_hash;
$job_mock->mock(
    _upload_log_file => sub {
        my ($self, @args) = @_;
        my $shared_hash = shared_hash;
        push @{$shared_hash->{uploaded_files}}, \@args;
        shared_hash $shared_hash;
        return $shared_hash->{upload_result};
    });
$job_mock->mock(
    _upload_asset => sub {
        my ($self, @args) = @_;
        my $shared_hash = shared_hash;
        push @{$shared_hash->{uploaded_assets}}, \@args;
        shared_hash $shared_hash;
        return $shared_hash->{upload_result};
    });

subtest 'Format reason' => sub {
    # call the function explicitely; further cases are covered in subsequent subtests where the
    # function is called indirectly
    is(
        undef,
        OpenQA::Worker::Job::_format_reason(undef, OpenQA::Jobs::Constants::PASSED, 'done'),
        'no reason added if it is just "done"',
    );
    is(undef, OpenQA::Worker::Job::_format_reason(undef, 'foo', 'foo'), 'no reason added if it equals the result',);
    is(
        'foobar',
        OpenQA::Worker::Job::_format_reason(undef, 'foo', 'foobar'),
        'unknown reason "passed as-is" if it differs from the result',
    );
    is(
        undef,
        OpenQA::Worker::Job::_format_reason(undef, OpenQA::Jobs::Constants::USER_CANCELLED, 'cancel'),
        'cancel omitted',
    );
};

subtest 'Interrupted WebSocket connection' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    $job->client->websocket_connection->emit_finish;
    wait_until_job_status_ok($job, 'accepted');
    is $job->status, 'accepted',
      'ws disconnects are not considered fatal one the job is accepted so it is still in accepted state';

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 1,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

subtest 'Interrupted WebSocket connection (before we can tell the WebUI that we want to work on it)' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 2, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    $job->client->websocket_connection->emit_finish;
    is $job->status, 'stopped', 'job is abandoned if unable to confirm to the web UI that we are working on it';
    like(
        exception { $job->start },
        qr/attempt to start job which is not accepted/,
        'starting job prevented unless accepted'
    );

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 2,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

subtest 'Job without id' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => undef, URL => $engine_url});
    like(
        exception { $job->start },
        qr/attempt to start job without ID and job info/,
        'starting job without id prevented'
    );
};

subtest 'Clean up pool directory' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 3, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');

    # Put some 'old' logs into the pool directory to verify whether those are cleaned up
    $pool_directory->child('autoinst-log.txt')->spurt('Hello Mojo!');

    # Try to start job
    combined_like sub { $job->start }, qr/Unable to setup job 3: this is not a real isotovideo/, 'error logged';
    wait_until_job_status_ok($job, 'stopped');
    is $job->status,      'stopped',                       'job is stopped due to the mocked error';
    is $job->setup_error, 'this is not a real isotovideo', 'setup error recorded';

    # verify old logs being cleaned up and worker-log.txt being created
    ok !-e $pool_directory->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted';
    ok -e $pool_directory->child('worker-log.txt'),    'worker log is there';

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 3),
            {
                json   => undef,
                path   => 'jobs/3/set_done',
                result => 'incomplete',
                reason => 'setup failure: this is not a real isotovideo',
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 3,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = shared_hash->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [
            [
                {
                    file => {
                        file     => "$pool_directory/worker-log.txt",
                        filename => 'worker-log.txt'
                    }}]
        ],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded because this test so far has none')
      or diag explain $uploaded_assets;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Job aborted during setup' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # simulate that the worker received SIGTERM during setup
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $engine_mock->mock(
        engine_workit => sub {
            $job->stop('quit');    # the worker would simply call $job->stop (while $job->start is being executed)
            return {error => 'worker interrupted'};
        });
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    $job->start;
    wait_until_job_status_ok($job, 'stopped');

    is $job->status,      'stopped',            'job is stopped due to the mocked error';
    is $job->setup_error, 'worker interrupted', 'setup error recorded';

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 8, duplicate => 1),
            {
                json   => undef,
                path   => 'jobs/8/set_done',
                result => 'incomplete',
                reason => 'quit',
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 8,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded')
      or diag explain $uploaded_assets;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Reason turned into "api-failure" if job duplication fails' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # pretend we have a running job; for the sake of this test it doesn't matter how it has
    # been started
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 9, URL => $engine_url});
    $job->{_status} = 'running';

    # stop the job pretending the job duplication didn't work
    $client->fail_job_duplication(1);
    $job->stop('quit');
    wait_until_job_status_ok($job, 'stopped');

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 9, duplicate => 1),
            {
                json   => undef,
                path   => 'jobs/9/set_done',
                result => 'incomplete',
                reason => 'api failure: fake API error on duplication after quit',
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);
    is_deeply($client->websocket_connection->sent_messages, [], 'no WebSocket messages expected')
      or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded') or diag explain $uploaded_assets;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
    $client->fail_job_duplication(0);
};

# Mock isotovideo engine (simulate successful startup and stop)
$engine_mock->mock(
    engine_workit => sub {
        my $job = shift;
        note 'pretending to run isotovideo';
        $job->once(
            uploading_results_concluded => sub {
                note "pretending job @{[$job->id]} is done";
                $job->stop('done');
            });
        $pool_directory->child('serial_terminal.txt')->spurt('Works!');
        $pool_directory->child('virtio_console1.log')->spurt('Works too!');
        return {child => $isotovideo->is_running(1)};
    });

subtest 'Successful job' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    my ($status, $is_uploading_results);
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            $is_uploading_results = $job->is_uploading_results;
            $status               = $job->status;
        });
    my $assets_public = $pool_directory->child('assets_public')->make_path;
    $assets_public->child('test.txt')->spurt('Works!');
    wait_until_job_status_ok($job, 'stopped');
    is $is_uploading_results, 0,          'uploading results concluded';
    is $status,               'stopping', 'job is stopping now';

    is $job->status,               'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0,         'uploading results concluded';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/4/status'
            },
            usual_status_updates(job_id => 4),
            {
                json => undef,
                path => 'jobs/4/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 4,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = shared_hash->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [
            [
                {
                    file => {
                        file     => "$pool_directory/serial_terminal.txt",
                        filename => 'serial_terminal.txt'
                    }}
            ],
            [
                {
                    file => {
                        file     => "$pool_directory/worker-log.txt",
                        filename => 'worker-log.txt'
                    }}
            ],
            [
                {
                    file => {
                        file     => "$pool_directory/virtio_console1.log",
                        filename => 'virtio_console1.log'
                    }}]
        ],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply(
        $uploaded_assets,
        [
            [
                {
                    asset => 'public',
                    file  => {
                        file     => "$pool_directory/assets_public/test.txt",
                        filename => 'test.txt'
                    }}]
        ],
        'would have uploaded assets'
    ) or diag explain $uploaded_assets;
    $assets_public->remove_tree;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Skip job' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => $engine_url});
    $job->skip;
    is $job->status, 'stopping', 'job is considered "stopping"';
    wait_until_job_status_ok($job, 'stopped');

    is_deeply(
        $client->sent_messages,
        [
            {
                json   => undef,
                path   => 'jobs/4/set_done',
                result => 'skipped',
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply($client->websocket_connection->sent_messages, [], 'job not accepted via WebSocket')
      or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = shared_hash->{uploaded_files};
    is_deeply($uploaded_files, [], 'no files uploaded') or diag explain $uploaded_files;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded') or diag explain $uploaded_assets;
};

subtest 'Livelog' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 5, URL => $engine_url});
    my @status;
    $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            push @status, $event_data->{status};
        });
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    $job->developer_session_running(1);
    combined_like(sub { $job->start_livelog }, qr/Starting livelog/, 'start of livelog logged');
    is $job->livelog_viewers, 1, 'has now one livelog viewer';
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            combined_like(sub { $job->stop_livelog }, qr/Stopping livelog/, 'stopping of livelog logged');
        });
    wait_until_job_status_ok($job, 'stopped');
    is $job->livelog_viewers, 0, 'no livelog viewers anymore';

    is $job->status,               'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0,         'uploading results concluded';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        log                   => {},
                        serial_log            => {},
                        serial_terminal       => {},
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        log                   => {},
                        serial_log            => {},
                        serial_terminal       => {},
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    outstanding_files           => 0,
                    outstanding_images          => 0,
                    upload_up_to                => undef,
                    upload_up_to_current_module => undef
                },
                path => '/liveviewhandler/api/v1/jobs/5/upload_progress'
            },
            usual_status_updates(job_id => 5),
            {
                json => undef,
                path => 'jobs/5/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 5,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = shared_hash->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [
            [
                {
                    file => {
                        file     => "$pool_directory/serial_terminal.txt",
                        filename => 'serial_terminal.txt'
                    }}
            ],
            [
                {
                    file => {
                        file     => "$pool_directory/worker-log.txt",
                        filename => 'worker-log.txt'
                    }}
            ],
            [
                {
                    file => {
                        file     => "$pool_directory/virtio_console1.log",
                        filename => 'virtio_console1.log'
                    }}]
        ],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded because this test so far has none')
      or diag explain $uploaded_assets;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'handling API failures' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 6, URL => $engine_url});
    my @status;
    $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            push @status, $event_data->{status};
        });
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            $client->last_error('fake API error');
            $job->stop('api-failure');
        });
    wait_until_job_status_ok($job, 'accepted');
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    is $client->register_called, 0, 'no re-registration attempted so far';
    wait_until_job_status_ok($job, 'stopped');
    is $client->register_called, 1, 'worker tried to register itself again after an API failure';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/6/status'
            },
            usual_status_updates(job_id => 6, no_overall_status => 1),
            {
                json   => undef,
                path   => 'jobs/6/set_done',
                result => 'incomplete',
                reason => 'api failure: fake API error',
            },
            {
                json   => undef,
                path   => 'jobs/6/set_done',
                reason => 'api failure: fake API error',
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 6,
                    type  => 'accepted'
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = shared_hash->{uploaded_files};
    is_deeply($uploaded_files, [], 'file upload skipped after API failure')
      or diag explain $uploaded_files;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'asset upload skipped after API failure')
      or diag explain $uploaded_assets;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'handle upload failure' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my $shared_hash = shared_hash;
    $shared_hash->{upload_result} = 0;
    shared_hash $shared_hash;

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    my @status;
    $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            push @status, $event_data->{status};
        });
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            $job->stop('done');
        });
    wait_until_job_status_ok($job, 'accepted');

    # Assume isotovideo generated some logs
    my $log_dir = $pool_directory->child('ulogs')->make_path;
    $log_dir->child('foo')->spurt('some log');
    $log_dir->child('bar')->spurt('another log');

    # Assume isotovideo generated some assets
    my $asset_dir = $pool_directory->child('assets_public')->make_path;
    $asset_dir->child('hdd1.qcow')->spurt('data');
    $asset_dir->child('hdd2.qcow')->spurt('more data');

    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');
    wait_until_job_status_ok($job, 'stopped');
    is $client->register_called, 1, 'worker tried to register itself again after an upload failure';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/7/status'
            },
            usual_status_updates(job_id => 7, no_overall_status => 1),
            {
                json   => undef,
                path   => 'jobs/7/set_done',
                result => 'incomplete',
                reason => 'api failure',
            },
            {
                json => undef,
                path => 'jobs/7/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    # note: It is intended that there are not further details about the API failure. The API error
    #       set for job 6 in the previous subtest is *not* supposed to be reported for the next job.

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 7,
                    type  => 'accepted'
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    # Verify that the upload has been skipped
    my $ok             = 1;
    my $uploaded_files = shared_hash->{uploaded_files};
    is(scalar @$uploaded_files, 2, 'only 2 files uploaded; stopped after first failure') or $ok = 0;
    my $log_name = $uploaded_files->[0][0]->{file}->{filename};
    ok($log_name eq 'bar' || $log_name eq 'foo', 'one of the logs attempted to be uploaded') or $ok = 0;
    is_deeply(
        $uploaded_files->[1],
        [
            {
                file => {
                    file     => "$pool_directory/serial_terminal.txt",
                    filename => 'serial_terminal.txt'
                }
            },
        ],
        'uploading autoinst log tried even though other logs failed'
    ) or $ok = 0;
    diag explain $uploaded_files unless $ok;
    my $uploaded_assets = shared_hash->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'asset upload skipped after previous upload failure')
      or diag explain $uploaded_assets;
    $log_dir->remove_tree;
    $asset_dir->remove_tree;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Job stopped while uploading' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    $job->{_status}               = 'running';
    $job->{_is_uploading_results} = 1;
    $job->stop;
    $job->emit(uploading_results_concluded => {});
    wait_until_job_status_ok($job, 'stopped');
    my $msg = $client->sent_messages->[-1];
    is $msg->{path}, 'jobs/7/set_done', 'job is done' or diag explain $client->sent_messages;
    $client->sent_messages([]);
};

# Mock isotovideo engine (simulate successful startup)
$engine_mock->mock(
    engine_workit => sub {
        my $job = shift;
        note 'pretending to run isotovideo';
        return {child => $isotovideo->is_running(1)};
    });

subtest 'Dynamic schedule' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # Create initial test schedule and test that it'll be loaded
    my $test_order = [
        {
            category => 'kernel',
            flags    => {fatal => 1},
            name     => 'install_ltp',
            script   => 'tests/kernel/install_ltp.pm'
        }];
    my $autoinst_status = {
        status       => 'running',
        current_test => 'install_ltp',
    };
    my $results_directory = $pool_directory->child('testresults')->make_path;

    my $status_file = $pool_directory->child(OpenQA::Worker::Job::AUTOINST_STATUSFILE);

    $results_directory->child('test_order.json')->spurt(encode_json($test_order));
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $job->accept;

    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    $status_file->spurt(encode_json($autoinst_status));

    $job->_upload_results_step_0_prepare(0, sub { });
    is_deeply $job->{_test_order}, $test_order, 'Initial test schedule';

    # Write updated test schedule and test it'll be reloaded
    push @$test_order,
      {
        category => 'kernel',
        flags    => {},
        name     => 'ping601',
        script   => 'tests/kernel/run_ltp.pm'
      };
    $results_directory->child('test_order.json')->spurt(encode_json($test_order));
    $job->_upload_results_step_0_prepare(0, sub { });
    is_deeply $job->{_test_order}, $test_order, 'Updated test schedule';

    # Write expected test logs and shut down cleanly
    $results_directory->child('result-install_ltp.json')->spurt('{"details": []}');
    $results_directory->child('result-ping601.json')->spurt('{"details": []}');
    $job->stop('done');
    wait_until_job_status_ok($job, 'stopped');

    # Cleanup
    $client->sent_messages([]);
    $client->websocket_connection->sent_messages([]);
    $results_directory->remove_tree;
    shared_hash {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'optipng' => sub {
    is OpenQA::Worker::Job::_optimize_image('foo'), undef, 'optipng call is "best-effort"';
};

done_testing();
