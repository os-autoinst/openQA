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

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use Mojo::Base -strict;
use Mojo::File 'tempdir';
use Mojolicious;
use Test::Fatal;
use Test::Output qw(combined_like combined_from);
use Test::MockModule;
use Test::More;
use OpenQA::Worker;
use OpenQA::Worker::Job;
use OpenQA::Worker::WebUIConnection;

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";

# enforce logging to stdout/stderr for combined_like checks
# note: The worker instantiates OpenQA::Setup which would configure logging to use the output
#       file specified via OPENQA_LOGFILE instead of stdout/stderr.
$ENV{OPENQA_LOGFILE} = undef;

# define take isotovideo
{
    package Test::FakeProcess;
    use Mojo::Base -base;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}
{
    package Test::FakeClient;
    use Mojo::Base -base;
    has webui_host => 'fake';
}
{
    package Test::FakeJob;
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
    }
    sub accept {
        my ($self) = @_;
        $self->is_accepted(1);
        $self->emit(status_changed => {job => $self, status => 'accepted'});
    }
    sub start { }
}

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
combined_like(
    sub { $worker->init; },
    qr/Ignoring host.*Working directory does not exist/,
    'hosts with non-existant working directory ignored and error logged'
);
is($worker->app->level, 'debug', 'log level set to debug with verbose switch');
my @webui_hosts = sort keys %{$worker->clients_by_webui_host};
is_deeply(\@webui_hosts, [qw(http://localhost:9527 https://remotehost)], 'client for each web UI host')
  or diag explain \@webui_hosts;


combined_like(
    sub { $worker->log_setup_info; },
    qr/.*http:\/\/localhost:9527,https:\/\/remotehost.*qemu_i386,qemu_x86_64.*/s,
    'setup info'
);

push(@{$worker->settings->parse_errors}, 'foo', 'bar');
combined_like(
    sub { $worker->log_setup_info; },
    qr/.*http:\/\/localhost:9527,https:\/\/remotehost.*qemu_i386,qemu_x86_64.*Errors occurred.*foo.*bar.*/s,
    'setup info with parse errors'
);

subtest 'capabilities' => sub {
    my $capabilities = $worker->capabilities;

    # ignore keys which are not always present and also not strictly required anyways
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
    my $worker_status;
    combined_like(
        sub {
            $worker_status = $worker->status;
        },
        qr/Worker cache not available: Cache service not reachable: Connection refused/,
        'worker cache error logged'
    );
    is_deeply(
        $worker_status,
        {
            type   => 'worker_status',
            status => 'broken',
            reason => 'Cache service not reachable: Connection refused'
        },
        'worker is broken if CACHEDIRECTORY set but worker cache not available'
    );

    delete $worker->settings->global_settings->{CACHEDIRECTORY};
};

subtest 'accept or skip next job' => sub {
    subtest 'get next job in queue' => sub {
        my @pending_jobs             = (0, [1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12);
        my @expected_iteration_steps = (
            [0, [[1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12]],
            [1, [[2, 3], [4, 5]]],
            [2, [3]],
            [3, []],
            [4, [5]],
            [5, []],
            [6,     [7,     [8,  9,    [10, 11]], 12]],
            [7,     [[8, 9, [10, 11]], 12]],
            [8,     [9,     [10, 11]]],
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
            if (!$ok) {
                diag explain $next_job;
                diag explain $current_sub_sequence;
            }
            $step_index += 1;
        }

        is(scalar @pending_jobs, 0, 'no pending jobs left');
    };

    subtest 'skip entire job queue (including sub queues) after failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs   = (
            Test::FakeJob->new(id => 0),
            Test::FakeJob->new(id => 1),
            Test::FakeJob->new(id => 2),
            Test::FakeJob->new(id => 3),
        );
        $worker->{_pending_jobs} = [$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]];

        # assume the last job failed: all jobs in the queue are expected to be skipped
        combined_like(
            sub {
                $worker->_accept_or_skip_next_job_in_queue('api-failure');
            },
            qr/Job 0.*finished.*skipped.*Job 1.*finished.*skipped.*Job 2.*finished.*skipped.*Job 3.*finished.*skipped/s,
            'skipping logged'
        );
        is($_->is_accepted, 0, 'job ' . $_->id . ' not accepted') for @jobs;
        is($_->is_skipped,  1, 'job ' . $_->id . ' skipped')      for @jobs;
        is_deeply($worker->{_pending_jobs}, [], 'all jobs skipeed');
    };

    subtest 'skip (only) a sub queue after a failure' => sub {
        my $worker = OpenQA::Worker->new({instance => 1});
        my @jobs   = (
            Test::FakeJob->new(id => 0),
            Test::FakeJob->new(id => 1),
            Test::FakeJob->new(id => 2),
            Test::FakeJob->new(id => 3),
        );
        $worker->{_pending_jobs} = [$jobs[0], [$jobs[1], $jobs[2]], $jobs[3]];

        # assume the last job has been completed: accept the next job in the queue
        $worker->_accept_or_skip_next_job_in_queue('done');
        is($_->is_accepted, 1, 'job ' . $_->id . ' accepted')    for ($jobs[0]);
        is($_->is_skipped,  0, 'job ' . $_->id . ' not skipped') for @jobs;
        is_deeply($worker->{_pending_jobs}, [[$jobs[1], $jobs[2]], $jobs[3]], 'next jobs still pending');

        # assume the last job has been completed: accept the next job in the queue
        $worker->_accept_or_skip_next_job_in_queue('done');
        is($_->is_accepted, 1, 'job ' . $_->id . ' accepted')    for ($jobs[1]);
        is($_->is_skipped,  0, 'job ' . $_->id . ' not skipped') for @jobs;
        is_deeply($worker->{_pending_jobs}, [[$jobs[2]], $jobs[3]], 'next jobs still pending');

        # assme the last job (job 0) failed: only the current sub queue (containing job 2) is skipped
        combined_like(
            sub {
                $worker->_accept_or_skip_next_job_in_queue('api-failure');
            },
            qr/Job 2.*finished.*skipped/s,
            'skipping logged'
        );
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
        $job_mock->mock(accept => sub { shift->_set_status(accepting => {}); });
        my %job_info = (
            sequence => [26, [27, 28]],
            data     => {
                26 => {id => 26, settings => {PARENT => 'job'}},
                27 => {id => 27, settings => {CHILD  => ' job 1'}},
                28 => {id => 28, settings => {CHILD  => 'job 2'}},
            },
        );
        $worker->enqueue_jobs_and_accept_first($client, \%job_info);
        ok($worker->current_job, 'current job assigned');
        is_deeply($worker->current_job->info, $job_info{data}->{26}, 'the current job is the first job in the sequence')
          or diag explain $worker->current_job->info;

        ok($worker->has_pending_jobs, 'worker has pending jobs');
        is_deeply($worker->pending_job_ids, [27, 28], 'pending job IDs returned as expected');
        is_deeply($worker->find_current_or_pending_job($_)->info, $job_info{data}->{$_}, 'can find all jobs by ID')
          for (26, 27, 28);
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
                $worker->stop;
                is($worker->is_stopping, 1, 'worker immediately considered stopping');
            });
        Mojo::IOLoop->start;    # supposed to stop itself via $worker->stop
        ok $client_quit_called, 'sent quit message to the web UI';

        my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
        my $expected_reason;
        $job_mock->mock(
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

subtest 'cleaning pool directory' => sub {
    my $pool_directory = tempdir('poolXXXX');
    $worker->pool_directory($pool_directory);

    # pretend QEMU is still running
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    $worker_mock->mock(is_qemu_running => sub { return 1; });

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

    combined_like(
        sub {
            $worker->_handle_client_status_changed($fake_client, {status => 'registering', reason => 'test'});
            $worker->_handle_client_status_changed($fake_client,
                {status => 'establishing_ws', reason => 'test', url => 'foo-bar'});
        },
        qr/Registering with openQA some-host.*Establishing ws connection via foo-bar/s,
        'registration and ws connection logged'
    );

    combined_like(
        sub {
            $fake_client->worker_id(42);
            $worker->_handle_client_status_changed($fake_client, {status => 'connected', reason => 'test'});
        },
        qr/Registered and connected via websockets with openQA host some-host and worker ID 42/,
        'connected logged'
    );

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

    combined_like(
        sub {
            $worker->_handle_client_status_changed($fake_client_2,
                {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
        },
        qr/Test disabling - ignoring server.*Stopping because registration/s,
        'worker stopped instantly when last client disabled and there is no job'
    );

    ok(!$worker->is_stopping, 'not planning to stop yet');
    combined_like(
        sub {
            $worker->current_job(1);
            $worker->_handle_client_status_changed($fake_client_2,
                {status => 'disabled', reason => 'test', error_message => 'Test disabling'});
        },
        qr/Test disabling - ignoring server.*Stopping after the current job because registration/s,
        'worker stopped after current job when last client disabled'
    );
    ok($worker->is_stopping, 'worker is stopping');

    combined_like(
        sub {
            $worker->_handle_client_status_changed($fake_client_2,
                {status => 'failed', reason => 'test', error_message => 'Test failure'});
        },
        qr/Test failure - trying again/s,
        'registration tried again on client failure'
    );
};

subtest 'handle job status changes' => sub {
    # mock cleanup
    my $worker_mock    = Test::MockModule->new('OpenQA::Worker');
    my $cleanup_called = 0;
    $worker_mock->mock(_clean_pool_directory => sub { $cleanup_called = 1; });

    # mock accepting and starting job
    my $job_mock = Test::MockModule->new('OpenQA::Worker::Job');
    $job_mock->mock(accept => sub { shift->{_status} = 'accepted'; });
    $job_mock->mock(start  => sub { shift->{_status} = 'started'; });
    $job_mock->mock(skip   => sub { shift->{_status} = 'skipped'; });

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

    combined_like(
        sub {
            $worker->_handle_job_status_changed($fake_job, {status => 'accepting', reason => 'test'});
            $worker->_handle_job_status_changed($fake_job, {status => 'setup',     reason => 'test'});
            $worker->_handle_job_status_changed($fake_job, {status => 'running',   reason => 'test'});
            $worker->_handle_job_status_changed($fake_job, {status => 'stopping',  reason => 'test'});
        },
        qr/Accepting job.*Setting job.*Running job.*Stopping job/s,
        'status updates logged'
    );

    subtest 'job accepted' => sub {
        is($fake_job->status, 'accepted', 'job has not been started so far');
        $worker->_handle_job_status_changed($fake_job, {status => 'accepted', reason => 'test'});
        is($fake_job->status, 'started', 'job has been accepted');
    };

    subtest 'job stopped' => sub {
        # stop job with error message and without cleanup enabled
        combined_like(
            sub {
                $worker->_handle_job_status_changed($fake_job,
                    {status => 'stopped', reason => 'test', error_message => 'some error message'});
            },
            qr/some error message.*Job 42 from some-host finished - reason: test/s,
            'status logged'
        );
        is($cleanup_called,             0,     'pool directory not cleaned up');
        is($worker->current_job,        undef, 'current job unassigned');
        is($worker->current_webui_host, undef, 'current web UI host unassigned');

        # enable cleanup and run availability check
        $worker->no_cleanup(0);
        $worker->check_availability;
        is($cleanup_called, 0, 'pool directory not cleaned up within periodic availability check');

        # stop job without error message and with cleanup enabled
        $worker->current_job($fake_job);
        $worker->current_webui_host('some-host');
        combined_like(
            sub {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
            },
            qr/Job 42 from some-host finished - reason: another/,
            'status logged'
        );
        is($cleanup_called, 1, 'pool directory cleaned up after job finished');

        subtest 'availability recomputed' => sub {
            # pretend QEMU is still running
            my $worker_mock = Test::MockModule->new('OpenQA::Worker');
            $worker_mock->mock(is_qemu_running => sub { return 17377; });

            # pretend we're still running the fake job and also that there's another pending job
            $worker->current_job($fake_job);
            $worker->{_pending_jobs} = $worker->{_current_sub_queue}
              = [my $pending_job = OpenQA::Worker::Job->new($worker, $fake_client, {id => 769, some => 'info'})];

            is($worker->current_error, undef, 'no error assumed so far');

            combined_like(
                sub {
                    $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'done'});
                },
qr/Job 42 from some-host finished - reason: done.*A QEMU instance using.*Skipping job 769 from queue because worker is broken/s,
                'status logged'
            );
            is(
                $worker->current_error,
                'A QEMU instance using the current pool directory is still running (PID: 17377)',
                'error status recomputed'
            );
            is($pending_job->status, 'skipped', 'pending job skipped');
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
    # fake critical errors
    Mojo::IOLoop->next_tick(sub { die 'fake some critical error on the event loop'; });
    my $worker_mock = Test::MockModule->new('OpenQA::Worker');
    $worker_mock->mock(stop => sub { die 'fake another critical error while handling the first error'; });

    # log whether worker tries to kill itself
    my $kill_called = 0;
    $worker_mock->mock(kill => sub { $kill_called = 1; });

    combined_like(
        sub {
            Mojo::IOLoop->start;
        },
        qr/Stopping because a critical error occurred.*Trying to kill ourself forcefully now/s,
        'log for initial critical error and forcefull kill after second error'
    );
    is($kill_called, 1, 'worker tried to kill itself in the end');
};

done_testing();
