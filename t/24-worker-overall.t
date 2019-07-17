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
use Mojo::File 'tempdir';
use Mojolicious;
use Test::Fatal;
use Test::Output 'combined_like';
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

subtest 'capabilities' => sub {
    my $capabilities      = $worker->capabilities;
    my @capabilities_keys = sort keys %$capabilities;
    is_deeply(
        \@capabilities_keys,
        [
            qw(
              cpu_arch cpu_modelname cpu_opmode host instance isotovideo_interface_version
              mem_max websocket_api_version worker_class
              )
        ],
        'capabilities contain expected information'
    ) or diag explain \@capabilities_keys;
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
        qr/Worker cache not available: Cache service not reachable\./,
        'worker cache error logged'
    );
    is_deeply(
        $worker_status,
        {
            type   => 'worker_status',
            status => 'broken',
            reason => 'Cache service not reachable.'
        },
        'worker is broken if CACHEDIRECTORY set but worker cache not available'
    );

    delete $worker->settings->global_settings->{CACHEDIRECTORY};
};

subtest 'check negative cases for is_qemu_running' => sub {
    my $pool_directory = tempdir('poolXXXX');
    $worker->pool_directory($pool_directory);

    $pool_directory->child('qemu.pid')->spurt('999999999999999999');
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID invalid');

    $pool_directory->child('qemu.pid')->spurt($$);
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID is not a qemu process');
};

subtest 'handle status changes' => sub {
    # mock cleanup
    my $worker_mock    = Test::MockModule->new('OpenQA::Worker');
    my $cleanup_called = 0;
    $worker_mock->mock(_clean_pool_directory => sub { $cleanup_called = 1; });

    # mock job startup
    my $job_mock           = Test::MockModule->new('OpenQA::Worker::Job');
    my $job_startup_called = 0;
    $job_mock->mock(start => sub { $job_startup_called = 1; });

    # assign fake client and job
    my $fake_client = OpenQA::Worker::WebUIConnection->new('some-host', {apikey => 'foo', apisecret => 'bar'});
    my $fake_job = OpenQA::Worker::Job->new($worker, $fake_client, {some => 'info'});
    $fake_job->{_id} = 42;
    $worker->current_job($fake_job);
    $worker->current_webui_host('some-host');

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
        is($job_startup_called, 0, 'job not started so far');
        $worker->_handle_job_status_changed($fake_job, {status => 'accepted', reason => 'test'});
        is($job_startup_called, 1, 'job started');
    };

    subtest 'job stopped' => sub {
        # stop job without cleanup enabled
        combined_like(
            sub {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'test'});
            },
            qr/Job 42 from some-host finished - reason: test/,
            'status logged'
        );
        is($cleanup_called,             0,     'pool directory not cleaned up');
        is($worker->current_job,        undef, 'current job unassigned');
        is($worker->current_webui_host, undef, 'current web UI host unassigned');

        $worker->check_availability;
        is($cleanup_called, 0, 'pool directory not cleaned up within periodic availability check');

        # stop job with cleanup enabled
        $worker->no_cleanup(0);
        $worker->current_job($fake_job);
        $worker->current_webui_host('some-host');
        combined_like(
            sub {
                $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
            },
            qr/Job 42 from some-host finished - reason: another/,
            'status logged'
        );
        is($cleanup_called, 1, 'pool directory cleaned up');
    };

    like(
        exception {
            $worker->_handle_job_status_changed($fake_job, {status => 'stopped', reason => 'another test'});
        },
        qr{Received job status update for job 42 \(stopped\) which is not the current one\.},
        'handling job status changed refused with no job',
    );
};

done_testing();
