#!/usr/bin/env perl

# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN {
    $ENV{OPENQA_UPLOAD_DELAY} = 0;
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;

use Test::Fatal;
use Test::Output qw(combined_like combined_unlike);
use Test::MockModule;
use Test::MockObject;
use Mojo::Collection;
use Mojo::File qw(path tempdir);
use Mojo::JSON 'encode_json';
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME DEFAULT_MAX_SETUP_TIME WORKER_COMMAND_CANCEL WORKER_COMMAND_QUIT
  WORKER_COMMAND_OBSOLETE WORKER_SR_SETUP_FAILURE WORKER_SR_TIMEOUT WORKER_EC_ASSET_FAILURE WORKER_EC_CACHE_FAILURE
  WORKER_SR_API_FAILURE WORKER_SR_DIED WORKER_SR_DONE);
use OpenQA::Worker::Job;
use OpenQA::Worker::Settings;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Worker::WebUIConnection;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Utils 'mock_io_loop';
use OpenQA::UserAgent;

sub wait_for_job {
    my ($job, $check_message, $relevant_event, $check_function, $timeout) = @_;
    $timeout //= 15;

    # Do not wait forever in case of problems
    my $error;
    my $timer = Mojo::IOLoop->timer(
        $timeout => sub {
            $error = "'$check_message' not happened after $timeout seconds";    # uncoverable statement
            Mojo::IOLoop->stop;    # uncoverable statement
        });

    # Watch the status event for changes
    my $cb = $job->on(
        $relevant_event => sub {
            note "$relevant_event emitted" unless defined $check_function;
            Mojo::IOLoop->stop if !defined $check_function || $check_function->(@_);
        });
    Mojo::IOLoop->start;
    $job->unsubscribe($relevant_event => $cb);
    Mojo::IOLoop->remove($timer);

    # Show caller perspective for failures
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is $error, undef, "no error waiting for '$check_message'";
}

sub wait_until_job_status_ok ($job, $status) {
    wait_for_job(
        $job,
        "job status changed to $status",
        status_changed => sub {
            my ($job, $event_data) = @_;
            my $new = $event_data->{status};
            note "job status change: $new";
            return $new eq $status;
        });
}

sub wait_until_uploading_logs_and_assets_concluded {
    my ($job) = @_;

    wait_for_job($job, 'job concluded uploading logs an assets', 'uploading_logs_and_assets_concluded');
}

# Fake worker, client and engine
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number => 1;
    has settings => sub { OpenQA::Worker::Settings->new(1, {}) };
    has pool_directory => undef;
}
{
    package Test::FakeClient;    # uncoverable statement count:2
    use Mojo::Base -base;
    has worker_id => 1;
    has webui_host => 'not relevant here';
    has working_directory => 'not relevant here';
    has testpool_server => 'not relevant here';
    has sent_messages => sub { [] };
    has websocket_connection => sub { OpenQA::Test::FakeWebSocketTransaction->new };
    has ua => sub { Mojo::UserAgent->new };
    has url => sub { Mojo::URL->new('example') };
    has register_called => 0;
    has last_error => undef;
    has fail_job_duplication => 0;
    has configured_retries => 5;
    sub send {
        my ($self, $method, $path, %args) = @_;
        my $params = $args{params};
        my %relevant_message_data = (path => $path, json => $args{json});
        for my $relevant_params (qw(result reason worker_id)) {
            next unless $params->{$relevant_params};
            $relevant_message_data{$relevant_params} = $params->{$relevant_params};
        }
        push(@{shift->sent_messages}, \%relevant_message_data);
        if ($self->fail_job_duplication && $path =~ qr/.*\/duplicate/) {
            $self->last_error('fake API error');
            return Mojo::IOLoop->next_tick(sub { $args{callback}->(0) });
        }
        Mojo::IOLoop->next_tick(sub { $args{callback}->({}) }) if $args{callback} && $args{callback} ne 'no';
    }
    sub reset_last_error { shift->last_error(undef) }
    sub send_status { push(@{shift->sent_messages}, @_) }
    sub register { shift->register_called(1) }
    sub add_context_to_last_error {
        my ($self, $context) = @_;
        $self->last_error($self->last_error . " on $context");
    }
    sub _retry_delay { 0 }
    sub evaluate_error { OpenQA::Worker::WebUIConnection::evaluate_error(@_) }
}
{
    package Test::FakeEngine;    # uncoverable statement count:2
    use Mojo::Base -base;
    has pid => 1;
    has errored => 0;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}

my $isotovideo = Test::FakeEngine->new;
my $worker = Test::FakeWorker->new;
my $pool_directory = tempdir('poolXXXX');
my $testresults_dir = $pool_directory->child('testresults')->make_path;
$testresults_dir->child('test_order.json')->spurt('[]');
$testresults_dir->child('.thumbs')->make_path;
$worker->pool_directory($pool_directory);
my $client = Test::FakeClient->new;
$client->ua->connect_timeout(0.1);
my $disconnected_client = Test::FakeClient->new(websocket_connection => undef);
my $engine_url = '127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
my $io_loop_mock = mock_io_loop(subprocess => 1);

# Define a function to get the usually expected status updates
sub usual_status_updates {
    my (%args) = @_;
    my $job_id = $args{job_id};

    my @expected_api_calls;
    push(
        @expected_api_calls,
        {
            path => "jobs/$job_id/status",
            json => {status => {uploading => 1, worker_id => 1}},
        });
    push(@expected_api_calls, {path => "jobs/$job_id/duplicate", json => undef}) if $args{duplicate};
    push(
        @expected_api_calls,
        {
            path => "jobs/$job_id/status",
            json => {
                status => {
                    cmd_srv_url => $engine_url,
                    result => {},
                    test_execution_paused => 0,
                    test_order => [],
                    worker_hostname => undef,
                    worker_id => 1
                }
            },
        }) unless $args{no_overall_status};
    return @expected_api_calls;
}

# Mock isotovideo engine (simulate startup failure)
my $engine_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
my $engine_result = {error => 'this is not a real isotovideo'};
$engine_mock->redefine(
    engine_workit => sub ($job, $callback) {
        note 'pretending isotovideo startup error';
        return $callback->($engine_result);
    });

# Mock log file and asset uploads to collect diagnostics
my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
my $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
sub upload_mock ($key, $self, @args) {
    push @{$upload_stats->{$key}}, \@args;
    return $upload_stats->{upload_result};
}
$job_mock->redefine(_upload_log_file => sub { upload_mock('uploaded_files', @_) });
$job_mock->redefine(_upload_asset => sub { upload_mock('uploaded_assets', @_) });

subtest 'Format reason' => sub {
    # call the function explicitly; further cases are covered in subsequent subtests where the
    # function is called indirectly
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1234});
    is($job->_format_reason(PASSED, WORKER_SR_DONE), undef, 'no reason added if it is just "done"');
    $job->{_result_upload_error} = 'Unable…';
    is($job->_format_reason(PASSED, WORKER_SR_DONE), 'api failure: Unable…', 'upload error considered API failure');
    like($job->_format_reason(INCOMPLETE, WORKER_SR_DIED), qr/died: .+/, 'generic phrase appended to died');
    is($job->_format_reason('foo', 'foo'), undef, 'no reason added if it equals the result');
    is($job->_format_reason('foo', 'foobar'), 'foobar', 'unknown reason "passed as-is" if it differs from the result');
    is($job->_format_reason(USER_CANCELLED, WORKER_COMMAND_CANCEL), undef, 'cancel omitted');
    like $job->_format_reason(TIMEOUT_EXCEEDED, WORKER_SR_TIMEOUT), qr/timeout: setup exceeded/, 'setup timeout';
    $job->{_engine} = 1;    # pretend isotovideo has been started
    like $job->_format_reason(TIMEOUT_EXCEEDED, WORKER_SR_TIMEOUT), qr/timeout: test execution exceeded/,
      'test timeout';
};

subtest 'Lost WebSocket connection' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $disconnected_client, {id => 1, URL => $engine_url});
    my $event_data;
    $job->on(status_changed => sub ($job, $data) { $event_data = $data });
    $job->accept;
    is $job->status, 'stopped', 'job has been stopped';
    is $event_data->{reason}, WORKER_SR_API_FAILURE, 'reason';
    like $event_data->{error_message}, qr/Unable to accept.*websocket connection to not relevant here has been lost./,
      'error message';
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
        [{json => {jobid => 1, type => 'accepted'}}],
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
        [{json => {jobid => 2, type => 'accepted'}}],
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
    combined_like { $job->start } qr/Unable to setup job 3: this is not a real isotovideo/, 'error logged';
    wait_until_job_status_ok($job, 'stopped');
    is $job->status, 'stopped', 'job is stopped due to the mocked error';
    is $job->setup_error, 'this is not a real isotovideo', 'setup error recorded';
    is $job->setup_error_category, WORKER_SR_SETUP_FAILURE, 'stop reason used as generic error category';

    # verify old logs being cleaned up and worker-log.txt being created
    ok !-e $pool_directory->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted';
    ok -e $pool_directory->child('worker-log.txt'), 'worker log is there';

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 3),
            {
                json => undef,
                path => 'jobs/3/set_done',
                result => 'incomplete',
                reason => 'setup failure: this is not a real isotovideo',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 3, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = $upload_stats->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [[{file => {file => "$pool_directory/worker-log.txt", filename => 'worker-log.txt'}}]],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded because this test so far has none')
      or diag explain $uploaded_assets;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Category from setup failure passed as reason' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => $engine_url});
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');

    # Try to start job
    $engine_result = {error => 'No active workers', category => WORKER_EC_CACHE_FAILURE};
    combined_like { $job->start } qr/Unable to setup job 4: No active workers/, 'error logged';
    wait_until_job_status_ok($job, 'stopped');
    is $job->status, 'stopped', 'job is stopped due to the mocked error';
    is $job->setup_error, 'No active workers', 'setup error recorded';
    is $job->setup_error_category, WORKER_EC_CACHE_FAILURE, 'stop reason used as generic error category';
};

subtest 'Job aborted because backend process died' => sub {
    my $state_file = $pool_directory->child('base_state.json');
    $state_file->remove;
    my $extended_reason = 'Migrate to file failed';
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $engine_mock->redefine(
        engine_workit => sub {
            # Let's pretend that the process died and wrote the message to the state file
            $state_file->spurt(qq({"component": "backend", "msg": "$extended_reason"}));
            $job->stop(WORKER_SR_DIED);
            return {error => 'worker interrupted'};
        });
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    $job->start;
    wait_until_job_status_ok($job, 'stopped');
    is(@{$client->sent_messages}[-1]->{reason}, "backend died: $extended_reason", 'reason propagated')
      or diag explain $client->sent_messages;

    $state_file->remove;
    $client->sent_messages([]);
    $client->websocket_connection->sent_messages([]);
};

subtest 'Job aborted because backend process died, multiple lines' => sub {
    my $state_file = $pool_directory->child('base_state.json');
    $state_file->remove;
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $engine_mock->redefine(
        engine_workit => sub {
            # Let's pretend that the process died and wrote the message to the state file
            $state_file->spurt(qq({"msg": "Lorem ipsum\\nDolor sit amet"}));
            $job->stop(WORKER_SR_DIED);
            return {error => 'worker interrupted'};
        });
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    $job->start;
    wait_until_job_status_ok($job, 'stopped');

    is(@{$client->sent_messages}[-1]->{reason}, 'died: Lorem ipsum', 'only first line added to reason')
      or diag explain $client->sent_messages;

    $state_file->remove;
    $client->sent_messages([]);
    $client->websocket_connection->sent_messages([]);
};

subtest 'Job aborted, broken state file' => sub {
    my $state_file = $pool_directory->child('base_state.json');
    $state_file->remove;
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $engine_mock->redefine(
        engine_workit => sub {
            # Let's pretend that the process died and wrote the message to the state file
            $state_file->spurt(qq({"msg": "test", ));
            $job->stop(WORKER_SR_DIED);
            return {error => 'worker interrupted'};
        });
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    $job->start;
    combined_like { wait_until_job_status_ok($job, 'stopped') } qr/failed to parse.*JSON/, 'warning about corrupt JSON';
    is(
        @{$client->sent_messages}[-1]->{reason},
        'terminated prematurely: Encountered corrupted state file, see log output for details',
        'reason propagated'
    ) or diag explain $client->sent_messages;
    combined_like {
        is(
            $job->_format_reason(PASSED, 'done'),
            'done: terminated with corrupted state file',
            'reason in case the job is nevertheless done'
          )
          or diag explain $client->sent_messages
    }
    qr/but failed to parse the JSON/, 'JSON error logged';

    $state_file->remove;
    $client->sent_messages([]);
    $client->websocket_connection->sent_messages([]);
};

subtest 'Job aborted during setup' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # simulate that the worker received SIGTERM during setup
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $engine_mock->redefine(
        engine_workit => sub ($job, $callback) {
            # stop the job like the real worker would do it within the signal handler (while $job->start is
            # being executed)
            $job->stop(WORKER_COMMAND_QUIT);
            return $callback->({error => 'worker interrupted'});
        });
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    $job->start;
    wait_until_job_status_ok($job, 'stopped');

    is $job->status, 'stopped', 'job is stopped due to the mocked error';
    is $job->setup_error, 'worker interrupted', 'setup error recorded';

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 8, duplicate => 1),
            {
                json => undef,
                path => 'jobs/8/set_done',
                result => 'incomplete',
                reason => 'quit: worker has been stopped or restarted',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 8, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded')
      or diag explain $uploaded_assets;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Reason turned into "api-failure" if job duplication fails' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # pretend we have a running job; for the sake of this test it doesn't matter how it has
    # been started
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 9, URL => $engine_url});
    $job->{_status} = 'running';
    combined_like {
        # stop the job pretending the job duplication didn't work
        $client->fail_job_duplication(1);
        $job->stop(WORKER_COMMAND_QUIT);
        wait_until_job_status_ok($job, 'stopped');
    }
    qr/Failed to duplicate/, 'error logged about duplication';

    is_deeply(
        $client->sent_messages,
        [
            usual_status_updates(job_id => 9, duplicate => 1),
            {
                json => undef,
                path => 'jobs/9/set_done',
                result => 'incomplete',
                reason => 'api failure: fake API error on duplication after quit',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);
    is_deeply($client->websocket_connection->sent_messages, [], 'no WebSocket messages expected')
      or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded') or diag explain $uploaded_assets;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
    $client->fail_job_duplication(0);
};

# Mock isotovideo engine (simulate successful startup and stop)
$engine_mock->redefine(
    engine_workit => sub ($job, $callback) {
        note 'pretending to run isotovideo';
        $job->once(
            uploading_results_concluded => sub {
                note "pretending job @{[$job->id]} is done";
                $job->stop(WORKER_SR_DONE);
            });
        $pool_directory->child('serial_terminal.txt')->spurt('Works!');
        $pool_directory->child('virtio_console1.log')->spurt('Works too!');
        return $callback->({child => $isotovideo->is_running(1)});
    });

subtest 'Successful job' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    my %settings = (EXTERNAL_VIDEO_ENCODER_CMD => 'ffmpeg …', GENERAL_HW_CMD_DIR => '/some/path', FOO => 'bar');
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => $engine_url, settings => \%settings});
    $worker->settings->global_settings->{EXTERNAL_VIDEO_ENCODER_BAR} = 'foo';
    $job->accept;
    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');

    my ($stop_reason, $is_uploading);
    $job->once(uploading_results_concluded => sub ($job, $result) { $is_uploading = $job->is_uploading_results });
    $job->on(status_changed => sub ($job, $result) { $stop_reason = $result->{reason} });
    my $assets_public = $pool_directory->child('assets_public')->make_path;
    $assets_public->child('test.txt')->spurt('Works!');

    combined_like { $job->start; wait_until_job_status_ok($job, 'stopped') }
    qr/isotovideo has been started/, 'isotovideo startup logged';
    subtest 'settings only allowed to be set within worker config deleted' => sub {
        my $settings = $job->settings;
        is($settings->{EXTERNAL_VIDEO_ENCODER_CMD},
            undef, 'video encoder settings deleted (should only be set within worker config)');
        is($settings->{GENERAL_HW_CMD_DIR},
            undef, 'general hw cmd dir deleted (should only be set within worker config)');
        is($settings->{EXTERNAL_VIDEO_ENCODER_BAR},
            'foo', 'settings (including video encoder settings) added from config');
        is($settings->{FOO}, 'bar', 'arbitrary settings kept');
    };

    is $is_uploading, 0, 'uploading results concluded';
    is $stop_reason, 'done', 'job stopped because it is done';
    is $job->status, 'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0, 'uploading results concluded';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname => undef,
                        worker_id => 1
                    }
                },
                path => 'jobs/4/status'
            },
            usual_status_updates(job_id => 4),
            {
                json => undef,
                path => 'jobs/4/set_done',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 4, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    # check whether asset upload has succeeded
    my $uploaded_files = $upload_stats->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [
            [{file => {file => "$pool_directory/worker-log.txt", filename => 'worker-log.txt'}}],
            [{file => {file => "$pool_directory/serial_terminal.txt", filename => 'serial_terminal.txt'}}],
            [{file => {file => "$pool_directory/virtio_console1.log", filename => 'virtio_console1.log'}}],
        ],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply(
        $uploaded_assets,
        [[{asset => 'public', file => {file => "$pool_directory/assets_public/test.txt", filename => 'test.txt'}}]],
        'would have uploaded assets'
    ) or diag explain $uploaded_assets;

    # assume asset upload would have failed
    $job_mock->redefine(_upload_log_file_or_asset => sub ($job, $params) { $params->{ulog} });
    $job->_set_status(running => {});
    $job->stop(WORKER_SR_DONE);
    wait_until_job_status_ok($job, 'stopped');
    is_deeply(
        $client->sent_messages,
        [
            {json => {status => {uploading => 1, worker_id => 1}}, path => 'jobs/4/status'},
            {json => undef, path => 'jobs/4/set_done', worker_id => 1, result => 'incomplete', reason => 'api failure'},
            {json => undef, path => 'jobs/4/set_done', worker_id => 1},
        ],
        'expected REST-API calls happened (last API call is actually useless and could be avoided)'
    ) or diag explain $client->sent_messages;
    is $client->register_called, 1, 're-registration attempted';
    $client->register_called(0)->sent_messages([])->websocket_connection->sent_messages([]);

    $assets_public->remove_tree;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

$job_mock->unmock('_upload_log_file_or_asset');

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
                json => undef,
                path => 'jobs/4/set_done',
                result => 'skipped',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply($client->websocket_connection->sent_messages, [], 'job not accepted via WebSocket')
      or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = $upload_stats->{uploaded_files};
    is_deeply($uploaded_files, [], 'no files uploaded') or diag explain $uploaded_files;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
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
    combined_like { $job->start } qr/isotovideo has been started/, 'isotovideo startup logged';

    $job->developer_session_running(1);
    combined_like { $job->start_livelog } qr/Starting livelog/, 'start of livelog logged';
    is $job->livelog_viewers, 1, 'has now one livelog viewer';
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            combined_like { $job->stop_livelog } qr/Stopping livelog/, 'stopping of livelog logged';
        });
    wait_until_job_status_ok($job, 'stopped');
    is $job->livelog_viewers, 0, 'no livelog viewers anymore';

    is $job->status, 'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0, 'uploading results concluded';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url => $engine_url,
                        log => {},
                        serial_log => {},
                        serial_terminal => {},
                        test_execution_paused => 0,
                        worker_hostname => undef,
                        worker_id => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    status => {
                        cmd_srv_url => $engine_url,
                        log => {},
                        serial_log => {},
                        serial_terminal => {},
                        test_execution_paused => 0,
                        worker_hostname => undef,
                        worker_id => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    outstanding_files => 0,
                    outstanding_images => 0,
                    upload_up_to => undef,
                    upload_up_to_current_module => undef
                },
                path => '/liveviewhandler/api/v1/jobs/5/upload_progress'
            },
            usual_status_updates(job_id => 5),
            {
                json => undef,
                path => 'jobs/5/set_done',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 5, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = $upload_stats->{uploaded_files};
    is_deeply(
        $uploaded_files,
        [
            [{file => {file => "$pool_directory/worker-log.txt", filename => 'worker-log.txt'}}],
            [{file => {file => "$pool_directory/serial_terminal.txt", filename => 'serial_terminal.txt'}}],
            [{file => {file => "$pool_directory/virtio_console1.log", filename => 'virtio_console1.log'}}],
        ],
        'would have uploaded logs'
    ) or diag explain $uploaded_files;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'no assets uploaded because this test so far has none')
      or diag explain $uploaded_assets;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
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
            $job->stop(WORKER_SR_API_FAILURE);
        });
    wait_until_job_status_ok($job, 'accepted');
    combined_like { $job->start } qr/isotovideo has been started/, 'isotovideo startup logged';

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
                        cmd_srv_url => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname => undef,
                        worker_id => 1
                    }
                },
                path => 'jobs/6/status'
            },
            usual_status_updates(job_id => 6, no_overall_status => 1),
            {
                json => undef,
                path => 'jobs/6/set_done',
                result => 'incomplete',
                reason => 'api failure: fake API error',
                worker_id => 1,
            },
            {
                json => undef,
                path => 'jobs/6/set_done',
                reason => 'api failure: fake API error',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 6, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    my $uploaded_files = $upload_stats->{uploaded_files};
    is_deeply($uploaded_files, [], 'file upload skipped after API failure')
      or diag explain $uploaded_files;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'asset upload skipped after API failure')
      or diag explain $uploaded_assets;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'handle upload failure' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    $upload_stats->{upload_result} = 0;

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
            $job->stop(WORKER_SR_DONE);
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

    combined_like { $job->start } qr/isotovideo has been started/, 'isotovideo startup logged';
    wait_until_job_status_ok($job, 'stopped');
    is $client->register_called, 1, 'worker tried to register itself again after an upload failure';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname => undef,
                        worker_id => 1
                    }
                },
                path => 'jobs/7/status'
            },
            usual_status_updates(job_id => 7, no_overall_status => 1),
            {
                json => undef,
                path => 'jobs/7/set_done',
                result => 'incomplete',
                reason => 'api failure',
                worker_id => 1,
            },
            {
                json => undef,
                path => 'jobs/7/set_done',
                worker_id => 1,
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    # note: It is intended that there are not further details about the API failure. The API error
    #       set for job 6 in the previous subtest is *not* supposed to be reported for the next job.

    is_deeply(
        $client->websocket_connection->sent_messages,
        [{json => {jobid => 7, type => 'accepted'}}],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);

    # Verify that the upload has been skipped
    my $ok = 1;
    my $uploaded_files = $upload_stats->{uploaded_files};
    is(scalar @$uploaded_files, 2, 'only 2 files uploaded; stopped after first failure') or $ok = 0;
    my $log_name = $uploaded_files->[0][0]->{file}->{filename};
    ok($log_name eq 'bar' || $log_name eq 'foo', 'one of the logs attempted to be uploaded') or $ok = 0;
    is_deeply(
        $uploaded_files->[1],
        [{file => {file => "$pool_directory/worker-log.txt", filename => 'worker-log.txt'}}],
        'uploading autoinst log tried even though other logs failed'
    ) or $ok = 0;
    diag explain $uploaded_files unless $ok;
    my $uploaded_assets = $upload_stats->{uploaded_assets};
    is_deeply($uploaded_assets, [], 'asset upload skipped after previous upload failure')
      or diag explain $uploaded_assets;
    $log_dir->remove_tree;
    $asset_dir->remove_tree;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'Job stopped while uploading' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    $client->sent_messages([]);
    $job->{_status} = 'running';
    $job->{_is_uploading_results} = 1;    # stopping the job should still go as far as uploading logs and assets
    $job->stop;
    is_deeply(
        $client->sent_messages,
        [{json => {status => {uploading => 1, worker_id => 1}}, path => 'jobs/7/status'}],
        'despite the ongoing result upload stopping has started by sending a job status update'
    ) or diag explain $client->sent_messages;
    wait_until_uploading_logs_and_assets_concluded($job);
    is $job->status, 'stopping', 'job has not been stopped yet';
    is_deeply $upload_stats->{uploaded_files},
      [
        [{file => {file => "$pool_directory/worker-log.txt", filename => 'worker-log.txt'}}],
        [{file => {file => "$pool_directory/serial_terminal.txt", filename => 'serial_terminal.txt'}}],
        [{file => {file => "$pool_directory/virtio_console1.log", filename => 'virtio_console1.log'}}],
      ],
      'logs uploaded'
      or diag explain $upload_stats->{uploaded_files};
    $upload_stats->{uploaded_files} = [];

    # pretend there's an image with thumbnail and a regular file to be uploaded
    my $test_image = 'test.png';
    path($job->_result_file_path(".thumbs/$test_image"))->touch;
    $job->images_to_send->{'098f6bcd4621d373cade4e832627b4f6'} = $test_image;
    $job->files_to_send->{'some-file.txt'} = 1;

    # track whether the final upload is really invoked
    # note: When omitting the call of the original functions the callback function for the upload is of course
    #       never invoked. In this case the test gets stuck because the job is never stopped. This shows that the worker
    #       really waits until the upload is done before continuing stopping the job.
    my ($final_result_upload_invoked, $final_image_upload_invoked);
    $job_mock->redefine(
        _upload_results => sub { $final_result_upload_invoked = 1; $job_mock->original('_upload_results')->(@_) });
    $job_mock->redefine(
        _upload_results_step_2_upload_images => sub {
            $final_image_upload_invoked = 1;
            $job_mock->original('_upload_results_step_2_upload_images')->(@_);
        });

    # assume the ongoing upload has concluded: this is supposed to continue stopping the job which is in turn
    # supposed to trigger the final upload
    $job->emit(uploading_results_concluded => {});

    wait_until_job_status_ok($job, 'stopped');
    ok $final_result_upload_invoked, 'final result upload invoked';
    ok $final_image_upload_invoked, 'final image upload invoked';
    my $msg = $client->sent_messages->[-1];
    is $msg->{path}, 'jobs/7/set_done', 'job is done' or diag explain $client->sent_messages;
    my @img_args = (image => 1, md5 => '098f6bcd4621d373cade4e832627b4f6');
    is_deeply $upload_stats->{uploaded_files},
      [
        [{file => {file => "$testresults_dir/test.png", filename => 'test.png'}, thumb => 0, @img_args}],
        [{file => {file => "$testresults_dir/.thumbs/test.png", filename => 'test.png'}, thumb => 1, @img_args}],
        [{file => {file => "$testresults_dir/some-file.txt", filename => 'some-file.txt'}, image => 0, thumb => 0}],
      ],
      'image, thumbnail and text file uploaded'
      or diag explain $upload_stats->{uploaded_files};
    $client->sent_messages([]);
    $upload_stats->{uploaded_files} = [];
};

subtest 'Final upload triggered and job inncompleted when job stopped due to obsoletion' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    my $res = {};
    $job_mock->redefine(_upload_results => sub ($self, $callback) { $callback->() });
    $job->_stop_step_5_2_upload(WORKER_COMMAND_OBSOLETE, sub ($result) { $res = $result });
    is $res->{result}, INCOMPLETE, 'job incompleted';
    is $res->{newbuild}, 1, 'newbuild parameter passed';
};

subtest 'Posting status during upload fails' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    my $callback_invoked;
    $job_mock->redefine(_upload_results_step_1_post_status => sub ($self, $status, $callback) { $callback->(undef) });
    combined_like {
        $job->_upload_results_step_0_prepare(sub { $callback_invoked = 1 })
    }
    qr/Aborting job because web UI doesn't accept new images anymore/, 'aborting logged';
    is $job->status, 'stopped', 'job immediately considered stopped (as it was still in status new)';
    Mojo::IOLoop->one_tick;    # the callback is supposed to be invoked on the next tick
    ok $callback_invoked, 'callback invoked also when posting status did not work';

    $callback_invoked = 0;
    $job_mock->redefine(stop => sub { fail 'stop should not have been invoked when already stopping' });
    combined_like {
        $job->_upload_results_step_0_prepare(sub { $callback_invoked = 1 })
    }
    qr/Unable to make final image uploads/, 'aborting logged when already stopping';
    Mojo::IOLoop->one_tick;    # the callback is supposed to be invoked on the next tick
    ok $callback_invoked, 'callback invoked also when posting status did not work (2)';
};

$job_mock->unmock('stop');

subtest 'Scheduling failure handled correctly' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 7, URL => $engine_url});
    my $callback_invoked;
    $pool_directory->child(OpenQA::Worker::Job::AUTOINST_STATUSFILE)
      ->spurt(encode_json({status => 'running', current_test => undef}));
    $testresults_dir->child('test_order.json')->remove;
    combined_like {
        $job->_upload_results_step_0_prepare(sub { $callback_invoked = 1 })
    }
    qr/Unable to read test_order\.json/, 'error logged';
    is $job->status, 'stopped', 'job immediately considered stopped (as it was still in status new)';
    Mojo::IOLoop->one_tick;    # the callback is supposed to be invoked on the next tick
    ok $callback_invoked, 'callback invoked also when posting status did not work';
};

# Mock isotovideo engine (simulate successful startup)
$engine_mock->redefine(
    engine_workit => sub ($job, $callback) {
        note 'pretending to run isotovideo';
        return $callback->({child => $isotovideo->is_running(1)});
    });

$job_mock->unmock($_) for qw(_upload_results _upload_results_step_1_post_status _upload_results_step_2_upload_images);

subtest 'Dynamic schedule' => sub {
    my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
    my $orig = \&OpenQA::Worker::Job::_read_json_file;
    my $read_schedule = 0;
    $job_mock->redefine(
        _read_json_file => sub {
            my ($self, $name) = @_;
            if ($name eq 'test_order.json') {
                $read_schedule++;
            }
            return $orig->($self, $name);
        });
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages, [], 'no REST-API calls yet';

    # Create initial test schedule and test that it'll be loaded
    my $test_order = [
        {
            category => 'kernel',
            flags => {fatal => 1},
            name => 'install_ltp',
            script => 'tests/kernel/install_ltp.pm'
        }];
    my $autoinst_status = {status => 'running', current_test => 'install_ltp'};
    my $results_directory = $pool_directory->child('testresults')->make_path;

    my $status_file = $pool_directory->child(OpenQA::Worker::Job::AUTOINST_STATUSFILE);

    $results_directory->child('test_order.json')->spurt(encode_json($test_order));
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 8, URL => $engine_url});
    $job->accept;

    is $job->status, 'accepting', 'job is now being accepted';
    wait_until_job_status_ok($job, 'accepted');
    combined_like { $job->start } qr/isotovideo has been started/, 'isotovideo startup logged';

    $status_file->spurt(encode_json($autoinst_status));

    $job->_upload_results_step_0_prepare(sub { });
    is_deeply $job->{_test_order}, $test_order, 'Initial test schedule';

    # do not reload test_order.json when it hasn't changed
    $autoinst_status->{current_test} = '';
    $status_file->spurt(encode_json($autoinst_status));
    $job->_upload_results_step_0_prepare(sub { });
    $job->_upload_results_step_0_prepare(sub { });
    $job->_upload_results_step_0_prepare(sub { });
    is($read_schedule, 1, 'test_order.json has only been read once');

    combined_unlike {
        $job->_upload_results_step_0_prepare(sub { })
    }
    qr/Test schedule has changed, reloading test_order\.json/, 'Did not report that schedule changed';
    # Write updated test schedule and test it'll be reloaded
    push @$test_order,
      {
        category => 'kernel',
        flags => {},
        name => 'ping601',
        script => 'tests/kernel/run_ltp.pm'
      };
    $results_directory->child('test_order.json')->spurt(encode_json($test_order));
    combined_like {
        $job->_upload_results_step_0_prepare(sub { })
    }
    qr/Test schedule has changed, reloading test_order\.json/, 'Reload test_order';
    is_deeply $job->{_test_order}, $test_order, 'Updated test schedule';

    # Write expected test logs and shut down cleanly
    $results_directory->child('result-install_ltp.json')->spurt('{"details": []}');
    $results_directory->child('result-ping601.json')->spurt('{"details": []}');
    $job->stop(WORKER_SR_DONE);
    wait_until_job_status_ok($job, 'stopped');

    # Cleanup
    $client->sent_messages([]);
    $client->websocket_connection->sent_messages([]);
    $results_directory->remove_tree;
    $upload_stats = {upload_result => 1, uploaded_files => [], uploaded_assets => []};
};

subtest 'optipng' => sub {
    is OpenQA::Worker::Job::_optimize_image('foo'), undef, 'optipng call is "best-effort"';
};

subtest '_read_module_result' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 9, URL => $engine_url});
    is undef, $job->_read_module_result('foo'), 'unable to read module result';

    my %res = (details => [{audio => 'recording.ogg', text => 'log.txt'}]);
    $pool_directory->child('testresults')->make_path->child('result-foo.json')->spurt(encode_json(\%res));
    is_deeply $job->_read_module_result('foo'), \%res, 'module result returned';
    ok $job->files_to_send->{'recording.ogg'}, 'audio file added to be sent';
    ok $job->files_to_send->{'log.txt'}, 'text file added to be sent';
};

subtest '_read_result_file and _reduce_test_order' => sub {
    my $test_order = [{name => 'my_result'}, {name => 'your_result'}, {name => 'our_result'}];
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 9, URL => $engine_url});
    my %module_res = (
        my_result => {name => 'my_module', extra_test_results => [{name => 'my_extra'}]},
        my_extra => {name => 'my_extra'},
    );
    $job_mock->redefine(_read_module_result => sub ($self, $test) { $module_res{$test} });
    $job->{_test_order} = $test_order;
    $job->{_current_test_module} = 'our_result';
    my $extra_test_order;
    my ($ret, $last_test_module) = $job->_read_result_file('your_result', $extra_test_order);
    is $last_test_module, 'my_result',
      'last test module is my_result because only for the one $job_mock provides a result';
    is $ret->{my_extra}->{name}, 'my_extra', 'extra_test_results covered' or diag explain $ret;
    is $extra_test_order, undef, 'the passed reference is not updated (do we need this?)';
    $job->_reduce_test_order('my_result');
    is_deeply $job->test_order, [{name => 'your_result'}, {name => 'our_result'}],
      'my_result removed from test order but not further test modules';

    $module_res{$_} = {name => $_} for qw(your_result our_result);
    ($ret, $last_test_module) = $job->_read_result_file('your_result', $extra_test_order);
    is $last_test_module, 'your_result', 'last test module is now your_result because that is the one to upload up to';

    $job->_reduce_test_order('our_result');
    is_deeply $job->test_order, [{name => 'our_result'}], 'our_result preserved as it is still the current module';
    # note: When pausing on a failed assert/check screen we upload up to the current module so the last module we have
    #       uploaded results for might still be in progress and still needs to be considered on further uploads.
};

subtest 'computing max job time and max setup time' => sub {
    my %settings;
    my ($max_job_time, $max_setup_time) = OpenQA::Worker::Job::_compute_timeouts(\%settings);
    is $max_job_time, DEFAULT_MAX_JOB_TIME, 'default scenario: default max job time)';
    is $max_setup_time, DEFAULT_MAX_SETUP_TIME, 'default scenario: default max setup time)';

    $settings{MAX_JOB_TIME} = sprintf('%d', DEFAULT_MAX_JOB_TIME / 2);
    $settings{MAX_SETUP_TIME} = sprintf('%d', DEFAULT_MAX_SETUP_TIME / 3);
    ($max_job_time, $max_setup_time) = OpenQA::Worker::Job::_compute_timeouts(\%settings);
    is $max_job_time, DEFAULT_MAX_JOB_TIME / 2, 'short scenario: max job time taken from settings';
    is $max_setup_time, DEFAULT_MAX_SETUP_TIME / 3, 'short scenario: max setup time taken from settings';

    $settings{TIMEOUT_SCALE} = '4';
    delete $settings{MAX_SETUP_TIME};
    ($max_job_time, $max_setup_time) = OpenQA::Worker::Job::_compute_timeouts(\%settings);
    is $max_job_time, DEFAULT_MAX_JOB_TIME * 2, 'max job time scaled';
    is $max_setup_time, DEFAULT_MAX_SETUP_TIME, 'max setup time not scaled';
    is_deeply [sort keys %settings], [qw(MAX_JOB_TIME TIMEOUT_SCALE)], 'no extra settings added so far';

    $settings{TIMEOUT_SCALE} = undef;
    $settings{MAX_JOB_TIME} = DEFAULT_MAX_JOB_TIME + 1;
    ($max_job_time, $max_setup_time) = OpenQA::Worker::Job::_compute_timeouts(\%settings);
    is $max_job_time, DEFAULT_MAX_JOB_TIME + 1, 'long scenario, NOVIDEO not specified';
    is $settings{NOVIDEO}, 1, 'NOVIDEO set to 1 for long scenarios';

    $settings{NOVIDEO} = 0;
    ($max_job_time, $max_setup_time) = OpenQA::Worker::Job::_compute_timeouts(\%settings);
    is $max_job_time, DEFAULT_MAX_JOB_TIME + 1, 'long scenario, NOVIDEO specified';
    is $settings{NOVIDEO}, 0, 'NOVIDEO not overridden if set to 0 explicitely';
    is_deeply [sort keys %settings], [qw(MAX_JOB_TIME NOVIDEO TIMEOUT_SCALE)], 'only expected settings added';
};

subtest 'handling timeout' => sub {
    my ($job, $event_data) = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => $engine_url});
    my $engine = Test::FakeEngine->new;
    $engine->{child} = Test::MockObject->new->set_always(session => Test::MockObject->new->set_true('_protect'));
    $job->_set_status(running => {});
    $job->on(status_changed => sub ($job, $data) { $event_data = $data });
    $job->_handle_timeout($engine);
    is $job->status, 'stopping', 'stop has been triggered';
    is $event_data->{reason}, WORKER_SR_TIMEOUT, 'stop reason is timeout';
};

subtest 'ignoring known images and files' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => $engine_url});
    $job->{_images_to_send} = {md5sum1 => 1, md5sum2 => 1};
    $job->{_files_to_send} = {filename1 => 1, filename2 => 1};
    $job->{_known_images} = ['md5sum1'];
    $job->{_known_files} = ['filename2'];
    $job->_ignore_known_images;
    $job->_ignore_known_files;
    is_deeply([keys %{$job->images_to_send}], ['md5sum2'], 'known image ignored; only unknown image left');
    is_deeply([keys %{$job->files_to_send}], ['filename1'], 'known file ignored; only unknown file left');
};

subtest 'known images and files populated from status update' => sub {
    my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
    my @fake_known_images = qw(md5sum1 md5sum2);
    my @fake_known_files = qw(filename1 filename2);
    $job_mock->redefine(
        _upload_results_step_1_post_status => sub {
            my ($self, $status, $callback) = @_;
            $callback->({known_images => \@fake_known_images, known_files => \@fake_known_files});
        });
    $job_mock->redefine(post_upload_progress_to_liveviewhandler => sub { });

    # fake *some* status so it does not attempt to read the test order
    path($worker->pool_directory, 'autoinst-status.json')->spurt('{"status":"setup"}');

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => $engine_url});
    $job->_upload_results_step_0_prepare();
    is_deeply($job->known_images, \@fake_known_images, 'known images populated from status update');
    is_deeply($job->known_files, \@fake_known_files, 'known files populated from status update');
};

subtest 'override job reason when qemu terminated with known issues by parsing autoinst-log' => sub {
    my @known_issues = (
        {
            reason => 'QEMU terminated: Failed to allocate KVM .* Cannot allocate memory',
            log_file_content =>
'[warn] !!! : qemu-system-ppc64: Failed to allocate KVM HPT of order 25 (try smaller maxmem?): Cannot allocate memory.',
            base_state_content => '{"component": "backend", "msg": "QEMU exited unexpectedly, see log for details"}'
        },
        {
            reason => 'QEMU terminated: Could not find .*smbd.*please install it',
            log_file_content =>
              '[debug] QEMU: qemu-system-x86_64: Could not find \'/usr/sbin/smbd\', please install it.',
            base_state_content => '{"component": "backend", "msg": "QEMU exited unexpectedly, see log for details"}'
        },
        {
            reason =>
'terminated prematurely: Encountered corrupted state file: No space left on device, see log output for details',
            log_file_content =>
'[debug] Unable to serialize fatal error: Can\'t write to file "base_state.json": No space left on device at /usr/lib/os-autoinst/bmwqemu.pm line 86.',
            base_state_content => 'foo boo'
        });
    foreach my $known_issue (@known_issues) {
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, URL => $engine_url});
        $engine_mock->redefine(
            engine_workit => sub {
                $pool_directory->child('base_state.json')->spurt($known_issue->{base_state_content});
                $pool_directory->child('autoinst-log.txt')->spurt($known_issue->{log_file_content});
                $job->stop(WORKER_SR_DIED);
                return {error => 'worker interrupted'};
            });
        $job->accept;
        wait_until_job_status_ok($job, 'accepted');
        $job->start;
        wait_until_job_status_ok($job, 'stopped');
        my $result = @{$client->sent_messages}[-1];
        is $result->{result}, 'incomplete', 'job result is incomplete';
        like $result->{reason}, qr/$known_issue->{reason}/, "The job incomplete with reason: $known_issue->{reason}";
    }
};

subtest 'Cache setup error handling' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, URL => $engine_url});
    $worker->settings->global_settings->{CACHEDIRECTORY} = '/var/lib/openqa/cache';
    my $extended_reason = "do_asset_caching return error";
    $engine_mock->redefine(
        do_asset_caching => sub ($job, $vars, $cache_dir, $assetkeys, $webui_host, $pooldir, $callback) {
            return $callback->({error => $extended_reason});
        });
    $engine_mock->unmock('engine_workit');
    $job->accept;
    wait_until_job_status_ok($job, 'accepted');
    combined_like { $job->start } qr/Unable to setup job 12: do_asset_caching return error/,
      'show the error message that is returned by do_asset_caching correctly';
};

subtest 'calculating md5sum of result file' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, URL => $engine_url});
    my $png = $pool_directory->child('foo.png');
    $png->spurt('not really a PNG');
    is $job->_calculate_file_md5('foo.png'), '454b28784a187cd782891a721b7ae31b', 'md5sum computed';
    $png->spurt('optimized');
    is $job->_calculate_file_md5('foo.png'), '454b28784a187cd782891a721b7ae31b', 'previous md5sum returned';
};

subtest 'posting setup status' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 13, URL => $engine_url});
    $job->post_setup_status;
    my %expected_msg = (json => {status => {setup => 1, worker_id => 1}}, path => 'jobs/13/status');
    is_deeply $client->sent_messages->[-1], \%expected_msg, 'sent status' or diag explain $client->sent_messages;
};

subtest 'asset upload' => sub {
    my $upload_mock = Test::MockModule->new('OpenQA::Client::Upload');
    my @params;
    my $mock_failure;
    my $chunk = Test::MockObject->new->set_always(index => 2)->set_always(total => 20)->set_always(end => 50)
      ->set_always(start => 25)->set_always(is_last => 0);
    my $normal_res = Test::MockObject->new->set_always(is_server_error => 0);
    my $failure_res
      = Test::MockObject->new->set_always(is_server_error => 1)->set_always(json => {error => 'fake error'});
    my $normal_tx = Test::MockObject->new->set_always(error => undef)->set_always(res => $normal_res);
    my $failure_tx = Test::MockObject->new->set_always(error => {code => 404, message => 'not found'})
      ->set_always(res => $failure_res);
    $upload_mock->redefine(
        asset => sub ($upload, @args) {
            # emit all events here to test the handlers (although in reality some events wouldn't occur together within
            # the same upload)
            $upload->emit('upload_local.prepare');
            $upload->emit('upload_chunk.prepare', Mojo::Collection->new);
            $upload->emit('upload_chunk.start');
            $upload->emit('upload_chunk.finish', $chunk);
            $upload->emit('upload_local.response', $normal_tx);
            $upload->emit('upload_chunk.response', $failure_tx);
            $upload->emit('upload_chunk.fail', undef, Test::MockObject->new->set_always(index => 3));
            $upload->emit('upload_chunk.error') if $mock_failure;
            push @params, \@args;
        });
    my $openqa_client = OpenQA::Client->new(base_url => 'http://base.url');
    $client->ua($openqa_client);
    $job_mock->unmock(qw(_upload_log_file _upload_asset));

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 14, URL => $engine_url});
    my %params = (file => {file => 'foo', filename => 'bar'});

    my $upload_res;
    combined_like { $upload_res = $job->_upload_asset(\%params) } qr/fake error.*404.*Upload failed for chunk 3/s,
      'upload logged';
    is $upload_res, 1, 'upload succeeded';
    is_deeply \@params, [[14, {asset => undef, chunk_size => 1000000, file => 'foo', name => 'bar', local => 1}]],
      'expected params passed'
      or diag explain \@params;

    $mock_failure = 1;
    combined_like { $upload_res = $job->_upload_asset(\%params) } qr/and all retry attempts have been exhausted/s,
      'error logged';
    is $upload_res, 0, 'upload failed';
};

subtest 'log file upload' => sub {
    my $ua_mock = Test::MockModule->new('Mojo::UserAgent');
    my ($req, $mock_failure);
    $ua_mock->redefine(
        start => sub ($ua, $tx) {
            $req = $tx->req;
            $tx->res(Mojo::Message::Response->new(code => 500, error => {message => 'Foo', code => 500}))
              if $mock_failure;
            return $tx;
        });

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 15, URL => $engine_url});
    is $job->_upload_log_file({file => {filename => 'bar', some => 'param'}}), 1, 'upload successful';
    is $req->method, 'POST', 'expected method';
    is $req->url, 'jobs/15/artefact', 'expected URL';
    like $req->build_body, qr/some: param/, 'expected parameters';

    my $upload_res;
    $mock_failure = 1;
    combined_like { $upload_res = $job->_upload_log_file({file => {filename => 'bar', some => 'param'}}) }
    qr|Uploading artefact bar.*500 resp.*attempts.*4/5.*1/5.*All 5 upload attempts have failed for bar.*500 resp|s,
      'attempts and errors logged';
    is $upload_res, 0, 'upload failed';

    my $callback_invoked = 0;
    $job->{_has_uploaded_logs_and_assets} = 1;    # assume final upload
    $job->{_files_to_send} = {bar => 1};
    combined_like {
        $job->_upload_results_step_2_upload_images(sub { $callback_invoked = [@_]; });
        Mojo::IOLoop->one_tick;
    }
    qr|All 5 upload attempts have failed for bar.*Error uploading bar: 500 response: Foo|s,
      'errors logged during final upload';
    is $job->{_result_upload_error}, 'Unable to upload images: Error uploading bar: 500 response: Foo',
      'upload failure tracked';
    is_deeply $callback_invoked, [], 'callback invoked';
};

done_testing();
