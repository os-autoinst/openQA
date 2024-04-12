#!/usr/bin/env perl
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings warning);

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use OpenQA::Test::TimeLimit '10';
use Data::Dumper;
use Mojo::File qw(tempdir tempfile path);
use Mojo::Util 'scope_guard';
use Mojolicious;
use Test::Fatal;
use Test::Output qw(combined_like combined_from);
use Test::MockModule;
use OpenQA::Constants qw(WORKER_COMMAND_QUIT WORKER_SR_API_FAILURE WORKER_SR_DIED WORKER_SR_DONE WORKER_SR_FINISH_OFF);
use OpenQA::Worker;
use OpenQA::Worker::Job;
use OpenQA::Worker::WebUIConnection;

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";

# enforce logging to stdout/stderr for combined_like checks
# note: The worker instantiates OpenQA::Setup which would configure logging to use the output
#       file specified via OPENQA_LOGFILE instead of stdout/stderr.
$ENV{OPENQA_LOGFILE} = undef;

# fake "/proc/loadavg"
my $load_avg_file = tempfile('worker-overall-load-avg-XXXXX');
my $load_avg_file_realpath = $load_avg_file->realpath;
$load_avg_file->spew('0.93 0.95 10.25 2/2207 1212');
$ENV{OPENQA_LOAD_AVG_FILE} = $load_avg_file_realpath;

# define fake isotovideo
{
    package Test::FakeProcess;    # uncoverable statement count:1
    use Mojo::Base -base;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}
{
    package Test::FakeClient;    # uncoverable statement count:2
    use Mojo::Base -base;
    has webui_host => 'fake';
    has worker_id => 42;
    has service_port_delta => 2;
    has api_calls => sub { [] };
    sub send {
        my ($self, $method, $path, %args) = @_;
        push(@{shift->api_calls}, $method, $path, $args{params});
    }
}
{
    package Test::FakeJob;    # uncoverable statement count:2
    use Mojo::Base 'Mojo::EventEmitter';
    has id => 42;
    has status => 'running';
    has is_skipped => 0;
    has is_accepted => 0;
    has client => sub { Test::FakeClient->new; };
    has name => 'test-job';
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
ok($worker->no_cleanup, 'no-cleanup flag works');
ok(my $settings = $worker->settings, 'settings instantiated');
my $global_settings = $settings->global_settings;
delete $global_settings->{LOG_DIR};
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
            type => 'worker_status',
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
            type => 'worker_status',
            status => 'working',
            job => {some => 'info'},
            current_webui_host => 'some host'
        },
        'worker is "working" if job assigned'
    );

    $worker->current_job(undef);
    $worker->settings->global_settings->{CACHEDIRECTORY} = 'foo';
    $worker->configure_cache_client;
    my $worker_status = $worker->status;
    my $reason = 'Worker cache not available via http://127.0.0.1:9530: Cache service info error: Connection refused';
    is_deeply(
        $worker_status,
        {type => 'worker_status', status => 'broken', reason => $reason},
        'worker is broken if CACHEDIRECTORY set but worker cache not available'
    );

    delete $worker->settings->global_settings->{CACHEDIRECTORY};
    $worker->configure_cache_client;
};

subtest 'accept or skip next job' => sub {
    subtest 'grab next job in queue' => sub {
        # define the job queue this test is going to process
        my @pending_jobs = (0, [1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12);
        # define expected results/states for each iteration step: [next job id, parent chain]
        my @expected_iteration_steps = (
            [0, [0]],
            [1, [0, 1]],
            [2, [0, 1, 2]],
            [3, [0, 1, 2]],
            [4, [0, 1, 4]],
            [5, [0, 1, 4]],
            [6, [0]],
            [7, [0]],
            [8, [0, 8]],
            [9, [0, 8]],
            [10, [0, 8, 10]],
            [11, [0, 8, 10]],
            [12, [0]],
            [undef, [0]],
        );

        # run `grab_next_job` on the job queue for the expected number of steps it'll take to process the queue
        my $step_index = 0;
        my %queue_info = (pending_jobs => \@pending_jobs, parent_chain => [], end_of_chain => 0);
        for my $expected_step (@expected_iteration_steps) {
            note "step $step_index ($queue_info{end_of_chain}): " . Dumper(\@pending_jobs);
            my $next_job = OpenQA::Worker::_grab_next_job(\@pending_jobs, \%queue_info);
            my @actual_step_results = ($next_job, $queue_info{parent_chain});
            my $ok = is_deeply \@actual_step_results, $expected_step, "iteration step $step_index";
            $ok or diag explain $_ for @actual_step_results;
            $step_index += 1;
        }
        is scalar @pending_jobs, 0, 'no pending jobs left';
    };

    my @stop_args = (status => 'stopped', reason => WORKER_SR_DONE, ok => 1);

    subtest 'skip entire job queue (including sub queues) after failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs = map { Test::FakeJob->new(id => $_) } (0 .. 3);
        $worker->_init_queue([$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]]);
        ok $worker->is_busy, 'worker considered busy without current job but pending ones';

        # assume the last job failed: all jobs in the queue are expected to be skipped
        combined_like { is $worker->_accept_or_skip_next_job_in_queue, 1, 'jobs accepted' }
        qr/Accepting job 0 from queue/s, 'acceptance logged';
        combined_like { $worker->_handle_job_status_changed($jobs[0], {@stop_args, reason => WORKER_SR_API_FAILURE}) }
        qr/Job 0 from fake finished - reason: api-failure.*Skipping job 1.*parent failed with api-failure/s,
          'skipping logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[0]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for ($jobs[0]);
        is $_->is_accepted, 0, 'job ' . $_->id . ' not accepted' for ($jobs[1], $jobs[2], $jobs[3]);
        is $_->is_skipped, 1, 'job ' . $_->id . ' skipped' for ($jobs[1], $jobs[2], $jobs[3]);
        subtest 'worker in clean state after skipping' => sub {
            ok !$worker->is_busy, 'worker not considered busy anymore';
            is_deeply $worker->current_job_ids, [], 'no job IDs remaining';
            is_deeply $worker->{_queue}->{pending_jobs}, [], 'no pending jobs left';
            is $worker->_accept_or_skip_next_job_in_queue, undef, 'no more jobs to skip/accept';
        };
    };

    subtest 'skip (only) a sub queue after a failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs = map { Test::FakeJob->new(id => $_) } (0 .. 3);
        $worker->_init_queue([$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]]);

        # assume the last job has been completed: accept the next job in the queue
        combined_like { is $worker->_accept_or_skip_next_job_in_queue, 1, 'job 0 accepted' }
        qr/Accepting job 0 from queue/s, 'acceptance of first job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[0]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for @jobs;
        is_deeply $worker->{_queue}->{pending_jobs}, [[$jobs[1], $jobs[2]], $jobs[3]], 'next jobs still pending (0)';

        # assume the last job has been completed: accept the next job in the queue
        combined_like { $worker->_handle_job_status_changed($jobs[0], {@stop_args}) }
        qr/Accepting job 1 from queue/s, 'acceptance of second job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[1]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for @jobs;
        is_deeply $worker->{_queue}->{pending_jobs}, [[$jobs[2]], $jobs[3]], 'next jobs still pending (1)';

        # assme the last job failed: only the current sub queue (containing job 2) is skipped
        combined_like { $worker->_handle_job_status_changed($jobs[1], {@stop_args, reason => WORKER_SR_DIED}) }
        qr/Skipping job 2.*parent.*died.*Job 2.*finished.*skipped/s, 'skipping of third job logged';
        is $_->is_accepted, 0, 'job ' . $_->id . ' not accepted' for ($jobs[2]);
        is $_->is_skipped, 1, 'job ' . $_->id . ' skipped' for ($jobs[2]);
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[3]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for ($jobs[3]);

        is_deeply $worker->{_queue}->{pending_jobs}, [], 'no more pending jobs';
    };

    subtest 'directly chained leafs not skipped after one fails' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs = map { Test::FakeJob->new(id => $_) } (0 .. 3);
        $worker->_init_queue([$jobs[0], [$jobs[1], $jobs[2], $jobs[3]]]);

        # assume the last job has been completed: accept the next job in the queue
        combined_like { is $worker->_accept_or_skip_next_job_in_queue, 1, 'job 0 accepted' }
        qr/Accepting job 0 from queue/s, 'acceptance of first job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[0]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for @jobs;
        is_deeply $worker->{_queue}->{pending_jobs}, [[$jobs[1], $jobs[2], $jobs[3]]], 'next jobs still pending (0)';

        # assume the last job has been completed: accept the next job in the queue
        combined_like { $worker->_handle_job_status_changed($jobs[0], {@stop_args}) }
        qr/Accepting job 1 from queue/s, 'acceptance of second job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[1]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for @jobs;
        is_deeply $worker->{_queue}->{pending_jobs}, [[$jobs[2], $jobs[3]]], 'next jobs still pending (1)';

        # assme the last job failed: only the current sub queue (containing job 2) is skipped
        combined_like { $worker->_handle_job_status_changed($jobs[1], {@stop_args}) }
        qr/Accepting job 2 from queue/s, 'acceptance of third job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[2]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' skipped' for ($jobs[2]);
        is $_->is_accepted, 0, 'job ' . $_->id . ' not accepted' for ($jobs[3]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for ($jobs[3]);

        # assme the last job failed: only the current sub queue (containing job 2) is skipped
        combined_like { $worker->_handle_job_status_changed($jobs[2], {@stop_args, ok => 0}) }
        qr/Accepting job 3 from queue/s, 'acceptance of forth job logged';
        is $_->is_accepted, 1, 'job ' . $_->id . ' accepted' for ($jobs[3]);
        is $_->is_skipped, 0, 'job ' . $_->id . ' not skipped' for ($jobs[3]);

        is_deeply $worker->{_queue}->{pending_jobs}, [], 'no more pending jobs';
    };

    subtest 'enqueue jobs and accept first' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my $client = Test::FakeClient->new;
        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        $job_mock->redefine(accept => sub { shift->_set_status(accepting => {}); });
        my %job_info = (
            sequence => [26, [27, 28]],
            data => {
                26 => {id => 26, settings => {PARENT => 'job'}},
                27 => {id => 27, settings => {CHILD => ' job 1'}},
                28 => {id => 28, settings => {CHILD => 'job 2'}},
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
        my $worker = OpenQA::Worker->new({instance => 1});
        my $client = Test::FakeClient->new;
        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        $job_mock->redefine(accept => sub { shift->_set_status(accepting => {}); });
        my %job_info = (
            sequence => [26, 27],
            data => {map { ($_ => {id => $_, settings => {}}) } (26, 27)},
        );
        $worker->enqueue_jobs_and_accept_first($client, \%job_info);
        is_deeply($worker->current_job_ids, [26, 27], 'jobs accepted/enqueued');
        $worker->skip_job(27, 'skip for testing');
        combined_like { $worker->_accept_or_skip_next_job_in_queue } qr/Skipping job 27 from queue/,
          'job 27 is skipped';
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
        my $client_mock = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
        my $client_quit_called = 0;
        my $quit = OpenQA::Worker::WebUIConnection->can('quit');
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
        $worker->kill;    # should not fail without job

        my $fake_job = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
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
    $pool_directory->child('qemu.pid')->spew('999999999999999999');
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID invalid');
    ok(!-f $pool_directory->child('qemu.pid'), 'PID file is cleaned up because the QEMU process is no longer running');

    $worker->no_cleanup(1);
    $pool_directory->child('qemu.pid')->spew($$);
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
    my $guard = scope_guard sub { chdir $FindBin::Bin };
    $worker->pool_directory($pool_directory);

    # pretend QEMU is still running
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    $worker_mock->redefine(is_qemu_running => sub { return 1; });

    my $pid_file = $pool_directory->child('qemu.pid')->spew($$);
    my $other_file = $pool_directory->child('other-file')->spew('foo');
    $worker->_clean_pool_directory;
    ok(-f $pid_file, 'PID file not deleted while QEMU still running');
    ok(!-f $other_file, 'other file deleted');

    $worker_mock->unmock('is_qemu_running');
    $worker->_clean_pool_directory;
    ok(!-f $pid_file, 'PID file deleted when QEMU not running');
};

subtest 'checking worker address' => sub {
    my $fqdn_lookup_mock = Test::MockModule->new('OpenQA::Worker::Settings');
    ok !$settings->is_local_worker, 'not considered local initially because we have https://remotehost configured';
    $global_settings->{WORKER_HOSTNAME} = undef;
    $settings->{_worker_address_auto_detected} = 0;
    $fqdn_lookup_mock->redefine(hostfqdn => undef);    # no hostname at all
    $settings->auto_detect_worker_address('some-fallback');
    is $global_settings->{WORKER_HOSTNAME}, 'some-fallback', 'fallback assigned without anything else';
    like $worker->check_availability, qr/Unable.*worker address/, 'the fallback is not considered good enough';

    $fqdn_lookup_mock->redefine(hostfqdn => 'foo.bar');
    is $worker->check_availability, undef, 'no error if FQDN becomes available';
    is $global_settings->{WORKER_HOSTNAME}, 'foo.bar', 'FQDN assigned';

    $fqdn_lookup_mock->redefine(hostfqdn => 'foobar');    # only a "short" hostname available but not an FQDN
    $global_settings->{WORKER_HOSTNAME} = 'foo';    # but assume WORKER_HOSTNAME has been specified explicitly …
    undef $settings->{_worker_address_auto_detected};    # … by resetting auto-detected/required flags
    is $worker->check_availability, undef, 'no error if worker address explicitly specified (also if no FQDN)';
    is $global_settings->{WORKER_HOSTNAME}, 'foo', 'explicitly specified worker address not overridden';

    $global_settings->{WORKER_HOSTNAME} = undef;    # assume WORKER_HOSTNAME has not been explicitly specified
    $settings->{_local} = 1;    # and that it is a local worker
    is $worker->check_availability, undef, 'a local worker does not require auto-detection to work';
    is $global_settings->{WORKER_HOSTNAME}, 'localhost', '"localhost" assumed as WORKER_HOSTNAME for local worker';
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

    my $job = OpenQA::Worker::Job->new($worker, $fake_client, {id => 43, some => 'info'});
    $job->{_accept_attempts} = 2;
    $worker->current_job($job);
    $fake_client->worker_id(42);
    combined_like {
        $worker->_handle_client_status_changed($fake_client, {status => 'connected', reason => 'test'});
        is $job->status, 'accepting', 'attempted to accept job';
        is $job->remaining_accept_attempts, 1, 'this cost the job one accept attempt';
        $worker->current_job(undef);
    }
    qr/Registered and connected.*with.*host some-host and worker ID 42.*Trying to accept.*43/s, 'connected logged';

    # assume one of the clients is disabled; it should be ignored
    $fake_client->status('disabled');

    my $output = combined_from {
        $worker->_handle_client_status_changed($fake_client,
            {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
    };
    like($output, qr/Test disabling - ignoring server/s, 'client disabled');
    unlike($output, qr/Stopping.*because registration/s, 'worker not stopped; there are still other clients');

    # see if the expected number of retries is performed
    $ENV{OPENQA_WORKER_CONNECT_INTERVAL} = 7;
    combined_like {
        $worker->_handle_client_status_changed($fake_client,
            {status => 'failed', reason => 'test', error_message => '500 response: unavailable'})
    }
    qr/trying again in 7 seconds/s, 'worker will attempt to retry later';

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
        $worker->current_job($job);
        $worker->_handle_client_status_changed($fake_client_2,
            {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
    }
    qr/Test disabling - ignoring server.*Stopping after the current job because registration/s,
      'worker stopped after current job when last client disabled';
    ok($worker->is_stopping, 'worker is stopping');

    is $worker->current_job->status, 'accepting', 'current job considered accepting';
    combined_like {
        $worker->_handle_client_status_changed($fake_client_2,
            {status => 'failed', reason => 'test', error_message => 'Test failure'});
    }
    qr/Test failure - trying again/s, 'registration tried again on client failure';
    is $worker->current_job->status, 'stopped', 'current job stopped after registration failure on last accept attempt';
};

subtest 'handle job status changes' => sub {
    # mock cleanup
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    my ($cleanup_called, $stop_called, $inform_webuis_called) = (0, 0);
    $worker_mock->redefine(_clean_pool_directory => sub { $cleanup_called = 1 });
    $worker_mock->redefine(stop => sub { $stop_called = $_[1]; $worker_mock->original('stop')->(@_) });
    $worker_mock->redefine(_inform_webuis_before_stopping => sub { $inform_webuis_called = 1 });

    # mock accepting and starting job
    my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
    $job_mock->redefine(accept => sub { shift->{_status} = 'accepted' });
    $job_mock->redefine(start => sub { shift->{_status} = 'started' });
    $job_mock->redefine(skip => sub { shift->{_status} = 'skipped: ' . ($_[1] // '?') });
    $job_mock->redefine(stop => sub { shift->{_status} = 'stopped: ' . ($_[1] // '?') });

    # assign fake client and job with cleanup
    my $fake_client = OpenQA::Worker::WebUIConnection->new('some-host', {apikey => 'foo', apisecret => 'bar'});
    $worker->current_job(undef);
    $worker->no_cleanup(0);
    $worker->accept_job($fake_client, {id => 42, some => 'info'});
    my $fake_job = $worker->current_job;
    ok($fake_job, 'job created');
    is($cleanup_called, 1, 'pool directory cleanup triggered');
    is($fake_job->status, 'accepted', 'job has been accepted');

    # assign fake client and job without cleanup
    $cleanup_called = 0;
    $fake_job->{_status} = 'new';
    $worker->current_job(undef);
    $worker->no_cleanup(1);
    $worker->accept_job($fake_client, {id => 42, some => 'info'});
    ok($fake_job = $worker->current_job, 'job created');
    is($cleanup_called, 0, 'pool directory cleanup not triggered');
    is($fake_job->status, 'accepted', 'job has been accepted');

    combined_like {
        $worker->_handle_job_status_changed($fake_job, {status => 'accepting', reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'setup', reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'running', reason => 'test'});
        $worker->_handle_job_status_changed($fake_job, {status => 'stopping', reason => 'test'});
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
        qr/Job 42 from some-host finished - reason: test.*some error message/s, 'status logged';
        is($cleanup_called, 0, 'pool directory not cleaned up');
        is($stop_called, 0, 'worker not stopped');
        is($worker->current_job, undef, 'current job unassigned');
        is($worker->current_webui_host, undef, 'current web UI host unassigned');

        # enable cleanup and run availability check
        $worker->no_cleanup(0);
        $worker->check_availability;
        is($cleanup_called, 0, 'pool directory not cleaned up within periodic availability check');

        # stop job without error message and with cleanup and TERMINATE_AFTER_JOBS_DONE enabled
        $worker->current_job($fake_job);
        $worker->current_webui_host('some-host');
        $worker->settings->global_settings->{TERMINATE_AFTER_JOBS_DONE} = 1;
        $worker->_init_queue([$fake_job]);    # assume there's another job in the queue
        combined_like {
            $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
        }
        qr/Job 42 from some-host finished - reason: another/, 'status logged';
        is($cleanup_called, 1, 'pool directory cleaned up after job finished');
        is($stop_called, 0, 'worker not stopped due to the other job added to queue');
        ok !$worker->has_pending_jobs, 'no more jobs pending';
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
            $worker->_init_queue([$next_job]);    # assume there's another job in the queue
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
            $worker->_init_queue([$next_job]);    # assume there's another job in the queue
            combined_like { $worker->handle_signal('HUP') } qr/Received signal HUP/, 'signal logged';
            is $worker->{_shall_terminate}, 1, 'worker is supposed to terminate';
            ok !$worker->{_finishing_off},
              'worker is still NOT supposed to finish off the current jobs due to previous SIGTERM';
            $worker->{_finishing_off} = undef;    # simulate we haven't already got SIGTERM
            $fake_job->{_status} = 0;
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
            my $pending_job = OpenQA::Worker::Job->new($worker, $fake_client, {id => 769, some => 'info'});
            $worker->current_job($fake_job);
            $worker->_init_queue([$pending_job]);
            $worker->{_shall_terminate} = 0;

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

            # assume the average load exceeds configured threshold
            $worker_mock->unmock('is_qemu_running');
            $worker->settings->global_settings->{CRITICAL_LOAD_AVG_THRESHOLD} = '10';
            is $worker->status->{status}, 'broken', 'worker considered broken when average load exceeds threshold';
            like $worker->current_error, qr/load 10\.25.*exceeding.*10/, 'error shows current load and threshold';

            # assume the error is gone
            $load_avg_file_realpath->remove;
            combined_like { is $worker->status->{status}, 'free', 'worker is free to take another job' }
            qr/unable to determine average load/i, 'warning about not being able to detect average load logged';
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
    combined_like {
        like warning { Mojo::IOLoop->start }, qr/$msg_1/, 'expected msg'
    }
    qr/$expected_logs.*$msg_2.*Trying to kill ourself forcefully now/s,
      'log for initial critical error and forcefull kill after second error';
    is $stop_called, 1, 'worker tried to stop the job';
    is $kill_called, 1, 'worker tried to kill itself in the end';
};

done_testing();
