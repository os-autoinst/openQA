#!/usr/bin/env perl
# Copyright (C) 2019-2021 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use OpenQA::Test::TimeLimit '10';
use Test::Most;
use Mojo::File 'tempdir';
use Mojo::Util 'scope_guard';
use Mojolicious;
use Test::Fatal;
use Test::Output qw(combined_like combined_from);
use Test::MockModule;
use OpenQA::Constants qw(WORKER_COMMAND_QUIT WORKER_SR_API_FAILURE WORKER_SR_DONE WORKER_SR_FINISH_OFF);
use OpenQA::Worker;
use OpenQA::Worker::Job;
use OpenQA::Worker::WebUIConnection;

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";

# enforce logging to stdout/stderr for combined_like checks
# note: The worker instantiates OpenQA::Setup which would configure logging to use the output
#       file specified via OPENQA_LOGFILE instead of stdout/stderr.
$ENV{OPENQA_LOGFILE} = undef;

# define fake isotovideo
{
    package Test::FakeProcess;    # uncoverable statement count:1
    use Mojo::Base -base;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}
{
    package Test::FakeClient;     # uncoverable statement count:2
    use Mojo::Base -base;
    has webui_host => 'fake';
    has worker_id  => 42;
    has api_calls  => sub { [] };
    sub send {
        my ($self, $method, $path, %args) = @_;
        push(@{shift->api_calls}, $method, $path, $args{params});
    }
}
{
    package Test::FakeJob;        # uncoverable statement count:2
    use Mojo::Base 'Mojo::EventEmitter';
    has id          => 42;
    has status      => 'running';
    has is_skipped  => 0;
    has is_accepted => 0;
    has client      => sub { Test::FakeClient->new; };
    has name        => 'test-job';
    sub skip {
        my ($self) = @_;
        $self->is_skipped(1);
        $self->emit(status_changed => {job => $self, status => 'stopped', reason => 'skipped'});
        return 1;
    }
    sub accept {
        my ($self) = @_;
        $self->is_accepted(1);
        $self->emit(status_changed => {job => $self, status => 'accepted'});
        return 1;
    }
    sub start { }
}
{
    package Test::FakeCacheServiceClientInfo;
    use Mojo::Base -base;
    has availability_error => 'Cache service info error: Connection refused';
}

my $cache_service_client_mock = Test::MockModule->new('OpenQA::CacheService::Client');
$cache_service_client_mock->redefine(info => sub { Test::FakeCacheServiceClientInfo->new });

like(
    exception {
        OpenQA::Worker->new({instance => 'foo'});
    },
    qr{.*the specified instance number \"foo\" is no number.*},
    'instance number must be a number',
);
my $worker = OpenQA::Worker->new({instance => 1, apikey => 'foo', apisecret => 'bar', verbose => 1, 'no-cleanup' => 1});
ok($worker->no_cleanup,              'no-cleanup flag works');
ok(my $settings = $worker->settings, 'settings instantiated');
delete $settings->global_settings->{LOG_DIR};
combined_like { $worker->init }
qr/Ignoring host.*Working directory does not exist/,
  'hosts with non-existent working directory ignored and error logged';
is($worker->app->level, 'debug', 'log level set to debug with verbose switch');
my @webui_hosts = sort keys %{$worker->clients_by_webui_host};
is_deeply(\@webui_hosts, [qw(http://localhost:9527 https://remotehost)], 'client for each web UI host')
  or diag explain \@webui_hosts;


combined_like { $worker->log_setup_info }
qr/.*http:\/\/localhost:9527,https:\/\/remotehost.*qemu_i386,qemu_x86_64.*/s, 'setup info';

push(@{$worker->settings->parse_errors}, 'foo', 'bar');
combined_like { $worker->log_setup_info }
qr/.*http:\/\/localhost:9527,https:\/\/remotehost.*qemu_i386,qemu_x86_64.*Errors occurred.*foo.*bar.*/s,
  'setup info with parse errors';

subtest 'delay and exec' => sub {
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    $worker_mock->redefine(init => 42);
    is $worker->exec, 42, 'return code passed from init';
};

subtest 'capabilities' => sub {
    my $capabilities = $worker->capabilities;

    # ignore keys which are not always present and also not strictly required anyways
    delete $capabilities->{cpu_flags};
    delete $capabilities->{cpu_opmode};
    delete $capabilities->{cpu_modelname};

    is_deeply(
        [sort keys %$capabilities],
        [
            qw(
              cpu_arch host instance isotovideo_interface_version
              mem_max websocket_api_version worker_class
            )
        ],
        'capabilities contain expected information'
    ) or diag explain $capabilities;

    # clear cached capabilities
    delete $worker->{_caps};

    subtest 'deduce worker class from CPU architecture' => sub {
        my $global_settings = $worker->settings->global_settings;
        delete $global_settings->{WORKER_CLASS};
        $global_settings->{ARCH} = 'aarch64';

        my $capabilities = $worker->capabilities;
        is_deeply(
            [sort keys %$capabilities],
            [
                qw(
                  cpu_arch host instance isotovideo_interface_version
                  mem_max websocket_api_version worker_class
                )
            ],
            'capabilities contain expected information'
        ) or diag explain $capabilities;
        is($capabilities->{worker_class}, 'qemu_aarch64', 'default worker class for architecture assigned');
    };

    subtest 'current job ID passed if it is running' => sub {
        $worker->current_job(Test::FakeJob->new);
        is($worker->capabilities->{job_id}, 42, 'job ID passed if job running');

        $worker->current_job(Test::FakeJob->new(status => 'new'));
        is($worker->capabilities->{job_id}, undef, 'job ID not passed if job new');
        $worker->current_job(Test::FakeJob->new(status => 'stopped'));
        is($worker->capabilities->{job_id}, undef, 'job ID not passed if job stopped');

        $worker->current_job(undef);
    };
};

subtest 'status' => sub {
    is_deeply(
        $worker->status,
        {
            type   => 'worker_status',
            status => 'free'
        },
        'worker is free by default'
    );

    my $job = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
    $worker->current_job($job);
    $worker->current_webui_host('some host');
    is_deeply(
        $worker->status,
        {
            type               => 'worker_status',
            status             => 'working',
            job                => {some => 'info'},
            current_webui_host => 'some host'
        },
        'worker is "working" if job assigned'
    );

    $worker->current_job(undef);
    $worker->settings->global_settings->{CACHEDIRECTORY} = 'foo';
    $worker->configure_cache_client;
    my $worker_status = $worker->status;
    is_deeply(
        $worker_status,
        {
            type   => 'worker_status',
            status => 'broken',
            reason => 'Worker cache not available: Cache service info error: Connection refused'
        },
        'worker is broken if CACHEDIRECTORY set but worker cache not available'
    );

    delete $worker->settings->global_settings->{CACHEDIRECTORY};
    $worker->configure_cache_client;
};

subtest 'accept or skip next job' => sub {
    subtest 'get next job in queue' => sub {
        my @pending_jobs             = (0, [1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12);
        my @expected_iteration_steps = (
            [0,     [[1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12]],
            [1,     [[2, 3], [4, 5]]],
            [2,     [3]],
            [3,     []],
            [4,     [5]],
            [5,     []],
            [6,     [7, [8, 9, [10, 11]], 12]],
            [7,     [[8, 9, [10, 11]], 12]],
            [8,     [9,                [10, 11]]],
            [9,     [[10, 11]]],
            [10,    [11]],
            [11,    []],
            [12,    []],
            [undef, []],
        );

        my $step_index = 0;
        for my $expected_step (@expected_iteration_steps) {
            my ($next_job, $current_sub_sequence) = OpenQA::Worker::_get_next_job(\@pending_jobs);
            my $ok = is_deeply([$next_job, $current_sub_sequence], $expected_step, "iteration step $step_index");
            $ok or diag explain $next_job and diag explain $current_sub_sequence;
            $step_index += 1;
        }

        is(scalar @pending_jobs, 0, 'no pending jobs left');
    };

    subtest 'skip entire job queue (including sub queues) after failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs   = map { Test::FakeJob->new(id => $_) } (0 .. 3);
        $worker->{_pending_jobs} = [$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]];
        ok($worker->is_busy, 'worker considered busy without current job but pending ones');

        # assume the last job failed: all jobs in the queue are expected to be skipped
        combined_like { is $worker->_accept_or_skip_next_job_in_queue(WORKER_SR_API_FAILURE), 1, 'jobs skipped' }
        qr/Job 0.*finished.*skipped.*Job 1.*finished.*skipped.*Job 2.*finished.*skipped.*Job 3.*finished.*skipped/s,
          'skipping logged';
        is($_->is_accepted, 0, 'job ' . $_->id . ' not accepted') for @jobs;
        is($_->is_skipped,  1, 'job ' . $_->id . ' skipped')      for @jobs;
        subtest 'worker in clean state after skipping' => sub {
            ok(!$worker->is_busy, 'worker not considered busy anymore');
            is_deeply($worker->current_job_ids, [], 'no job IDs remaining');
            is_deeply($worker->{_pending_jobs}, [], 'no pending jobs left');
            is($worker->_accept_or_skip_next_job_in_queue(WORKER_SR_API_FAILURE), undef, 'no more jobs to skip/accept');
        };
    };

    subtest 'skip (only) a sub queue after a failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs   = map { Test::FakeJob->new(id => $_) } (0 .. 3);
        $worker->{_pending_jobs} = [$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]];

        # assume the last job has been completed: accept the next job in the queue
        is($worker->_accept_or_skip_next_job_in_queue(WORKER_SR_DONE), 1, 'next job accepted');
        is($_->is_accepted, 1, 'job ' . $_->id . ' accepted')    for ($jobs[0]);
        is($_->is_skipped,  0, 'job ' . $_->id . ' not skipped') for @jobs;
        is_deeply($worker->{_pending_jobs}, [[$jobs[1], $jobs[2]], $jobs[3]], 'next jobs still pending');

        # assume the last job has been completed: accept the next job in the queue
        is($worker->_accept_or_skip_next_job_in_queue(WORKER_SR_DONE), 1, 'next job accepted');
        is($_->is_accepted, 1, 'job ' . $_->id . ' accepted')    for ($jobs[1]);
        is($_->is_skipped,  0, 'job ' . $_->id . ' not skipped') for @jobs;
        is_deeply($worker->{_pending_jobs}, [[$jobs[2]], $jobs[3]], 'next jobs still pending');

        # assme the last job (job 0) failed: only the current sub queue (containing job 2) is skipped
        combined_like {
            is $worker->_accept_or_skip_next_job_in_queue(WORKER_SR_API_FAILURE), 1, 'jobs skipped/accepted'
        }
        qr/Job 2.*finished.*skipped/s, 'skipping logged';
        is($_->is_accepted, 0, 'job ' . $_->id . ' not accepted') for ($jobs[2]);
        is($_->is_skipped,  1, 'job ' . $_->id . ' skipped')      for ($jobs[2]);
        is($_->is_accepted, 1, 'job ' . $_->id . ' accepted')     for ($jobs[3]);
        is($_->is_skipped,  0, 'job ' . $_->id . ' not skipped')  for ($jobs[3]);

        is_deeply($worker->{_pending_jobs}, [], 'no more pending jobs');
    };

    subtest 'enqueue jobs and accept first' => sub {
        my $worker   = OpenQA::Worker->new({instance => 1});
        my $client   = Test::FakeClient->new;
        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        $job_mock->redefine(accept => sub { shift->_set_status(accepting => {}); });
        my %job_info = (
            sequence => [26, [27, 28]],
            data     => {
                26 => {id => 26, settings => {PARENT => 'job'}},
                27 => {id => 27, settings => {CHILD  => ' job 1'}},
                28 => {id => 28, settings => {CHILD  => 'job 2'}},
            },
        );
        ok(!$worker->is_busy, 'worker not considered busy so far');
        $worker->enqueue_jobs_and_accept_first($client, \%job_info);
        ok($worker->current_job, 'current job assigned');
        is_deeply($worker->current_job->info, $job_info{data}->{26}, 'the current job is the first job in the sequence')
          or diag explain $worker->current_job->info;

        ok($worker->has_pending_jobs, 'worker has pending jobs');
        is_deeply($worker->pending_job_ids, [27, 28], 'pending job IDs returned as expected');
        is_deeply($worker->current_job_ids, [26, 27, 28], 'worker keeps track of job IDs');
        ok($worker->is_busy, 'worker is considered busy');
        is_deeply($worker->find_current_or_pending_job($_)->info, $job_info{data}->{$_}, 'can find all jobs by ID')
          for (26, 27, 28);
    };

    subtest 'mark job to be skipped' => sub {
        my $worker   = OpenQA::Worker->new({instance => 1});
        my $client   = Test::FakeClient->new;
        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        $job_mock->redefine(accept => sub { shift->_set_status(accepting => {}); });
        my %job_info = (
            sequence => [26, 27],
            data     => {map { ($_ => {id => $_, settings => {}}) } (26, 27)},
        );
        $worker->enqueue_jobs_and_accept_first($client, \%job_info);
        is_deeply($worker->current_job_ids, [26, 27], 'jobs accepted/enqueued');
        $worker->skip_job(27, 'skip for testing');
        combined_like { $worker->_accept_or_skip_next_job_in_queue(WORKER_SR_DONE) }
        qr/Skipping job 27 from queue/, 'job 27 is skipped';
        is_deeply(
            $client->api_calls,
            [post => 'jobs/27/set_done', {reason => 'skip for testing', result => 'skipped', worker_id => 42}],
            'API call for skipping done'
        ) or diag explain $client->api_calls;
    };
};

subtest 'stopping' => sub {
    is($worker->is_stopping, 0, 'worker not stopping so far');

    subtest 'stop current job' => sub {
        $worker->current_job(undef);
        $worker->stop_current_job;    # should be noop but not fail

        my $fake_job = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
        $worker->current_job($fake_job);
        $worker->stop_current_job;
        is($fake_job->status, 'stopped', 'job stopped');
    };

    subtest 'stop worker gracefully' => sub {
        my $client_mock        = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
        my $client_quit_called = 0;
        my $quit               = OpenQA::Worker::WebUIConnection->can('quit');
        $client_mock->redefine(
            quit => sub {
                $client_quit_called++;
                $quit->(@_);
            });
        $worker->current_job(undef);
        Mojo::IOLoop->next_tick(
            sub {
                combined_like { $worker->stop } qr/Informing.*offline/, 'informing web UIs logged';
                is($worker->is_stopping, 1, 'worker immediately considered stopping');
            });
        Mojo::IOLoop->start;    # supposed to stop itself via $worker->stop
        ok $client_quit_called, 'sent quit message to the web UI';

        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        my $expected_reason;
        $job_mock->redefine(
            stop => sub {
                my ($self, $reason) = @_;
                $self->{_status} = 'stopped';
                is($reason, $expected_reason, 'job stopped due to ' . $expected_reason);
            });

        my $fake_job_setup = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
        $fake_job_setup->{_status} = 'setup';
        $worker->current_job($fake_job_setup);
        $worker->stop($expected_reason = 'some reason');
        is($fake_job_setup->status, 'stopped', 'job stopped during setup');

        my $fake_job_running = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
        $fake_job_running->{_status} = 'running';
        $worker->current_job($fake_job_running);
        $expected_reason = undef;    # do not expect worker to stop immediately after stop
        $worker->stop('some other reason');
        $expected_reason = 'some other reason';
        is($worker->is_stopping, 1, 'worker is stopping');
        Mojo::IOLoop->one_tick;
        is($fake_job_running->status, 'stopped', 'job stopped while running');
    };

    subtest 'kill worker' => sub {
        $worker->current_job(undef);
        $worker->kill;               # should not fail without job

        my $fake_job        = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
        my $fake_isotovideo = Test::FakeProcess->new;
        $fake_job->{_engine} = {child => $fake_isotovideo};
        $worker->current_job($fake_job);
        $worker->kill;
        is($fake_isotovideo->is_running, 0, 'isotovideo stopped');
    };

    # restore the worker's internal _shall_terminate for subsequent tests
    $worker->{_shall_terminate} = 0;
};

subtest 'check negative cases for is_qemu_running' => sub {
    my $pool_directory = tempdir('poolXXXX');
    $worker->pool_directory($pool_directory);

    $worker->no_cleanup(0);
    $pool_directory->child('qemu.pid')->spurt('999999999999999999');
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID invalid');
    ok(!-f $pool_directory->child('qemu.pid'), 'PID file is cleaned up because the QEMU process is no longer running');

    $worker->no_cleanup(1);
    $pool_directory->child('qemu.pid')->spurt($$);
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID is not a qemu process');
    ok(-f $pool_directory->child('qemu.pid'), 'PID file is not cleaned up when --no-cleanup is enabled');
};

subtest 'checking and cleaning pool directory' => sub {
    $worker->pool_directory(undef);
    $worker->{_pool_directory_lock_fd} = undef;
    is $worker->check_availability, 'No pool directory assigned.', 'availability error if no pool directory assigned';

    # assign temporary pool dir
    # note: Using scope guard to "get out" of pool directory again so we can delete the tempdir.
    my $pool_directory = tempdir('poolXXXX');
    my $guard          = scope_guard sub { chdir $FindBin::Bin };
    $worker->pool_directory($pool_directory);

    # pretend QEMU is still running
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    $worker_mock->redefine(is_qemu_running => sub { return 1; });

    my $pid_file   = $pool_directory->child('qemu.pid')->spurt($$);
    my $other_file = $pool_directory->child('other-file')->spurt('foo');
    $worker->_clean_pool_directory;
    ok(-f $pid_file,    'PID file not deleted while QEMU still running');
    ok(!-f $other_file, 'other file deleted');

    $worker_mock->unmock('is_qemu_running');
    $worker->_clean_pool_directory;
    ok(!-f $pid_file, 'PID file deleted when QEMU not running');
};

subtest 'handle client status changes' => sub {
    my $fake_client = OpenQA::Worker::WebUIConnection->new('some-host', {apikey => 'foo', apisecret => 'bar'});
    my $fake_client_2
      = OpenQA::Worker::WebUIConnection->new('yet-another-host', {apikey => 'foo2', apisecret => 'bar2'});
    my $worker
      = OpenQA::Worker->new({instance => 1, apikey => 'foo', apisecret => 'bar', verbose => 1, 'no-cleanup' => 1});
    $worker->settings->webui_hosts([qw(some-host yet-another-host)]);
    $worker->clients_by_webui_host({'some-host' => $fake_client, 'yet-another-host' => $fake_client_2});

    combined_like {
        $worker->_handle_client_status_changed($fake_client, {status => 'registering', reason => 'test'});
        $worker->_handle_client_status_changed($fake_client,
            {status => 'establishing_ws', reason => 'test', url => 'foo-bar'});
    }
    qr/Registering with openQA some-host.*Establishing ws connection via foo-bar/s,
      'registration and ws connection logged';

    combined_like {
        $fake_client->worker_id(42);
        $worker->_handle_client_status_changed($fake_client, {status => 'connected', reason => 'test'});
    }
    qr/Registered and connected via websockets with openQA host some-host and worker ID 42/, 'connected logged';

    # assume one of the clients is disabled; it should be ignored
    $fake_client->status('disabled');

    my $output = combined_from {
        $worker->_handle_client_status_changed($fake_client,
            {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
    };
    like($output, qr/Test disabling - ignoring server/s, 'client disabled');
    unlike($output, qr/Stopping.*because registration/s, 'worker not stopped; there are still other clients');

    # assume all clients are disabled; worker should stop
    $fake_client_2->status('disabled');

    combined_like {
        $worker->_handle_client_status_changed($fake_client_2,
            {status => 'disabled', reason => 'test', error_message => 'Test disabling'})
    }
    qr/Test disabling - ignoring server.*Stopping because registration/s,
      'worker stopped instantly when last client disabled and there is no job';

    ok(!$worker->is_stopping, 'not planning to stop yet');
    combined_like {
        $worker->current_job(1);
        $worker->_handle_client_status_changed($fake_client_2,
            {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
    }
    qr/Test disabling - ignoring server.*Stopping after the current job because registration/s,
      'worker stopped after current job when last client disabled';
    ok($worker->is_stopping, 'worker is stopping');

    combined_like {
        $worker->_handle_client_status_changed($fake_client_2,
            {status => 'failed', reason => 'test', error_message => 'Test failure'});
    }
    qr/Test failure - trying again/s, 'registration tried again on client failure';
};

subtest 'handle job status changes' => sub {
    # mock cleanup
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    my ($cleanup_called, $stop_called, $inform_webuis_called) = (0, 0);
    $worker_mock->redefine(_clean_pool_directory => sub { $cleanup_called = 1 });
    $worker_mock->redefine(stop                  => sub { $stop_called = $_[1]; $worker_mock->original('stop')->(@_) });
    $worker_mock->redefine(_inform_webuis_before_stopping => sub { $inform_webuis_called = 1 });

    # mock accepting and starting job
    my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
    $job_mock->redefine(accept => sub { shift->{_status} = 'accepted' });
    $job_mock->redefine(start  => sub { shift->{_status} = 'started' });
    $job_mock->redefine(skip   => sub { shift->{_status} = 'skipped: ' . ($_[1] // '?') });
    $job_mock->redefine(stop   => sub { shift->{_status} = 'stopped: ' . ($_[1] // '?') });

    # assign fake client and job with cleanup
    my $fake_client = OpenQA::Worker::WebUIConnection->new('some-host', {apikey => 'foo', apisecret => 'bar'});
    $worker->current_job(undef);
    $worker->no_cleanup(0);
    $worker->accept_job($fake_client, {id => 42, some => 'info'});
    my $fake_job = $worker->current_job;
    ok($fake_job, 'job created');
    is($cleanup_called,   1,          'pool directory cleanup triggered');
    is($fake_job->status, 'accepted', 'job has been accepted');

    # assign fake client and job without cleanup
    $cleanup_called = 0;
    $fake_job->{_status} = 'new';
    $worker->current_job(undef);
    $worker->no_cleanup(1);
    $worker->accept_job($fake_client, {id => 42, some => 'info'});
    ok($fake_job = $worker->current_job, 'job created');
    is($cleanup_called,   0,          'pool directory cleanup not triggered');
    is($fake_job->status, 'accepted', 'job has been accepted');

    combined_like {
        $worker->_handle_job_status_changed($fake_job, {status => 'accepting', reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'setup',     reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'running',   reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'stopping',  reason => 'test'});
    }
    qr/Accepting job.*Setting job.*Running job.*Stopping job/s, 'status updates logged';

    combined_like {
        $fake_job->emit(uploading_results_concluded => {upload_up_to => 'foo'});
        $fake_job->emit(uploading_results_concluded => {upload_up_to => ''});
        $fake_job->{_current_test_module} = 'bar';
        $fake_job->emit(uploading_results_concluded => {upload_up_to => ''});
    }
    qr/Upload concluded \(up to foo\).*\(no current module\).*\(at bar\)/s, 'upload status logged';

    subtest 'job accepted' => sub {
        is($fake_job->status, 'accepted', 'job has not been started so far');
        $worker->_handle_job_status_changed($fake_job, {status => 'accepted', reason => 'test'});
        is($fake_job->status, 'started', 'job has been accepted');
    };

    subtest 'job stopped' => sub {
        # assume the job is always in status 'setup' to ease the following tests
        $job_mock->redefine(status => 'setup');

        # stop job with error message and without cleanup enabled
        combined_like {
            $worker->_handle_job_status_changed($fake_job,
                {status => 'stopped', reason => 'test', error_message => 'some error message'});
        }
        qr/some error message.*Job 42 from some-host finished - reason: test/s, 'status logged';
        is($cleanup_called,             0,     'pool directory not cleaned up');
        is($stop_called,                0,     'worker not stopped');
        is($worker->current_job,        undef, 'current job unassigned');
        is($worker->current_webui_host, undef, 'current web UI host unassigned');

        # enable cleanup and run availability check
        $worker->no_cleanup(0);
        $worker->check_availability;
        is($cleanup_called, 0, 'pool directory not cleaned up within periodic availability check');

        # stop job without error message and with cleanup and TERMINATE_AFTER_JOBS_DONE enabled
        $worker->current_job($fake_job);
        $worker->current_webui_host('some-host');
        $worker->settings->global_settings->{TERMINATE_AFTER_JOBS_DONE} = 1;
        $worker->{_pending_jobs} = [$fake_job];    # assume there's another job in the queue
        combined_like {
            $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
        }
        qr/Job 42 from some-host finished - reason: another/, 'status logged';
        is($cleanup_called, 1, 'pool directory cleaned up after job finished');
        is($stop_called,    0, 'worker not stopped due to the other job added to queue');
        combined_like {
            $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'yet another test'});
        }
        qr/Job 42 from some-host finished - reason: yet another/, 'status of 2nd job logged';
        is($stop_called, WORKER_COMMAND_QUIT, 'worker stopped after no more jobs left in the queue');

        $worker->settings->global_settings->{TERMINATE_AFTER_JOBS_DONE} = 0;

        subtest 'stopping behavior when receiving SIGTERM' => sub {
            # assume a job is running while while receiving SIGTERM
            $stop_called = $inform_webuis_called = $worker->{_shall_terminate} = $fake_job->{_status} = 0;
            my $next_job = OpenQA::Worker::Job->new($worker, $fake_job->client, {id => 43});
            $worker->current_job($fake_job);
            $worker->{_pending_jobs} = [$next_job];    # assume there's another job in the queue
            combined_like { $worker->handle_signal('TERM') } qr/Received signal TERM/, 'signal logged';
            is $worker->{_shall_terminate}, 1, 'worker is supposed to terminate';
            ok !$worker->{_finishing_off}, 'worker is not supposed to finish off the current jobs';
            is $stop_called, WORKER_COMMAND_QUIT, 'worker stopped with WORKER_COMMAND_QUIT';
            is $fake_job->{_status}, 'stopped: ' . WORKER_COMMAND_QUIT, 'job stopped with WORKER_COMMAND_QUIT';

            # test how the job being stopped is handled further
            combined_like {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => WORKER_COMMAND_QUIT});
            }
            qr/Job 42 from some-host finished - reason: quit/, 'first job being stopped is logged';
            is $next_job->{_status}, 'skipped: ' . WORKER_COMMAND_QUIT, 'next job skipped with WORKER_COMMAND_QUIT';
            is $inform_webuis_called, 0,
              'web UIs not informed so far; we still need to wait until the next job is processed';

            # test how the next job being skipped is handled further
            $stop_called = 0;
            combined_like {
                $worker->_handle_job_status_changed($next_job, {status => 'stopped', reason => WORKER_COMMAND_QUIT});
            }
            qr/Job 43 from some-host finished - reason: quit/, 'next job stopped is logged';
            is $stop_called, WORKER_COMMAND_QUIT, 'worker stopped with WORKER_COMMAND_QUIT after last job';
            is $inform_webuis_called, 1, 'web UIs informed that worker goes offline';
        };

        subtest 'stopping behavior when receiving SIGHUP' => sub {
            # assume a job is running while while receiving SIGHUP
            $stop_called = $inform_webuis_called = $worker->{_shall_terminate} = 0;
            my $next_job = OpenQA::Worker::Job->new($worker, $fake_job->client, {id => 43});
            $worker->current_job($fake_job);
            $worker->{_pending_jobs} = [$next_job];    # assume there's another job in the queue
            combined_like { $worker->handle_signal('HUP') } qr/Received signal HUP/, 'signal logged';
            is $worker->{_shall_terminate}, 1, 'worker is supposed to terminate';
            ok !$worker->{_finishing_off},
              'worker is still NOT supposed to finish off the current jobs due to previous SIGTERM';
            $worker->{_finishing_off} = undef;         # simulate we haven't already got SIGTERM
            $fake_job->{_status}      = 0;
            combined_like { $worker->handle_signal('HUP') } qr/Received signal HUP/, 'signal logged (2)';
            ok $worker->{_finishing_off}, 'worker is supposed to finish off the current jobs after SIGHUP';
            is $stop_called, WORKER_SR_FINISH_OFF, 'worker stopped with WORKER_SR_FINISH_OFF';
            is $fake_job->{_status}, 0, 'job NOT stopped';
            subtest 'receiving a 2nd SIGHUP makes no further difference' => sub {
                combined_like { $worker->handle_signal('HUP') } qr/Received signal HUP/, 'signal logged (3)';
                ok $worker->{_finishing_off}, 'worker is supposed to finish off the current jobs after SIGHUP';
                is $stop_called, WORKER_SR_FINISH_OFF, 'worker stopped with WORKER_SR_FINISH_OFF';
                is $fake_job->{_status}, 0, 'job NOT stopped';
            };

            # assume the job finished by itself and test how this is handled further
            combined_like {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => WORKER_SR_DONE});
            }
            qr/Job 42 from some-host finished - reason: done/, 'first job being done is logged';
            is $next_job->{_status}, 'accepted', 'next job accepted';

            # test how the next job being skipped is handled further
            $stop_called = 0;
            is $inform_webuis_called, 0,
              'web UIs not informed so far; we still need to wait until the next job is processed';
            combined_like {
                $worker->_handle_job_status_changed($next_job, {status => 'stopped', reason => WORKER_SR_DONE});
            }
            qr/Job 43 from some-host finished - reason: done/, 'next job being done is logged';
            is $stop_called, WORKER_COMMAND_QUIT, 'worker stopped with WORKER_COMMAND_QUIT after last job';
            is $inform_webuis_called, 1, 'web UIs informed that worker goes offline';
        };

        $job_mock->unmock('status');

        subtest 'availability/current error recomputed when starting the next pending job and when idling' => sub {
            # pretend QEMU is still running
            my $worker_mock = Test::MockModule->new('OpenQA::Worker');
            $worker_mock->redefine(is_qemu_running => sub { return 17377; });

            # pretend we're still running the fake job and also that there's another pending job
            $worker->current_job($fake_job);
            $worker->{_pending_jobs} = $worker->{_current_sub_queue}
              = [my $pending_job = OpenQA::Worker::Job->new($worker, $fake_client, {id => 769, some => 'info'})];

            is($worker->current_error, undef, 'no error assumed so far');

            combined_like {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'done'});
            }
qr/Job 42 from some-host finished - reason: done.*A QEMU instance using.*Skipping job 769 from queue because worker is broken/s,
              'status logged';
            is(
                $worker->current_error,
                'A QEMU instance using the current pool directory is still running (PID: 17377)',
                'error status recomputed'
            );
            is $pending_job->status, 'skipped: ?', 'pending job is supposed to be skipped due to the error';
            combined_like {
                $worker->_handle_job_status_changed($pending_job, {status => 'stopped', reason => 'skipped'});
            }
            qr/Job 769 from some-host finished - reason: skipped/s, 'assume skipping of job 769 is complete';
            is $worker->status->{status}, 'broken', 'worker still considered broken';

            # assume the error is gone
            $worker_mock->unmock('is_qemu_running');
            is $worker->status->{status}, 'free', 'worker is free to take another job';
            is $worker->current_error, undef, 'current error is cleared by the querying the status';
        };
    };

    like(
        exception {
            $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
        },
        qr{Received job status update for job 42 \(stopped\) which is not the current one\.},
        'handling job status changed refused with no job',
    );
};

subtest 'handle critical error' => sub {
    # fake critical errors and trace whether stop is called
    $worker->{_shall_terminate} = 0;
    my $msg_1 = 'fake some critical error on the event loop';
    my $msg_2 = 'fake another critical error while handling the first error';
    Mojo::IOLoop->next_tick(sub { note 'simulating initial error'; die $msg_1 });
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    my $stop_called = 0;
    $worker_mock->redefine(
        stop => sub ($worker, $reason) {
            ++$stop_called;
            is $reason, 'exception', 'worker stopped due to exception';
            note 'simulating further error when stopping';
            die $msg_2;
        });

    # trace whether worker tries to kill itself
    my $kill_called = 0;
    $worker_mock->redefine(kill => sub { ++$kill_called; $worker_mock->original('kill')->(@_) });

    my $expected_logs = 'Stopping because a critical error occurred.*Another error occurred';
    combined_like { Mojo::IOLoop->start }
    qr/$msg_1.*$expected_logs.*$msg_2.*Trying to kill ourself forcefully now/s,
      'log for initial critical error and forcefull kill after second error';
    is $stop_called, 1, 'worker tried to stop the job';
    is $kill_called, 1, 'worker tried to kill itself in the end';
};

done_testing();
