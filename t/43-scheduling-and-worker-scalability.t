#!/usr/bin/env perl
# Copyright (C) 2020 SUSE LLC
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
use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Test::Database;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Utils
  qw(create_user_for_workers create_webapi setup_share_dir create_websocket_server),
  qw(stop_service setup_fullstack_temp_dir);
use Test::More;
use Test::Warnings;
use Test::MockModule;
use Time::HiRes 'sleep';
use File::Path 'make_path';
use Scalar::Util 'looks_like_number';
use Mojo::File 'path';
use Mojo::Util 'dumper';

BEGIN {
    # set default worker and job count
    $ENV{SCALABILITY_TEST_JOB_COUNT}    //= 5;
    $ENV{SCALABILITY_TEST_WORKER_COUNT} //= 2;

    # allow the scheduler to assigns all jobs within one tick (needs to be in BEGIN block because the env variable
    # is assigned to constant)
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = $ENV{SCALABILITY_TEST_JOB_COUNT};
}

# skip test if not explicitly enabled
plan skip_all => 'set SCALABILITY_TEST to run the scalability test' unless $ENV{SCALABILITY_TEST};

# read number of workers to spawn from environment variable; skip test entirely if variable not present
# similar to other fullstack tests
my $worker_count = $ENV{SCALABILITY_TEST_WORKER_COUNT};
my $job_count    = $ENV{SCALABILITY_TEST_JOB_COUNT} // $worker_count;
BAIL_OUT 'invalid SCALABILITY_TEST_WORKER_COUNT/SCALABILITY_TEST_JOB_COUNT'
  unless looks_like_number($worker_count) && looks_like_number($job_count) && $worker_count > 0 && $job_count > 0;
note("Running scalability test with $worker_count worker(s) and $job_count job(s).");
note('Set SCALABILITY_TEST_WORKER_COUNT/SCALABILITY_TEST_JOB_COUNT to adjust this.');

# generate free ports for the web UI and the web socket server and mock service_port to use them
# FIXME: So far the fullstack tests only generate the web UI port and derive the required port for other services
#        from it. Apparently sometimes these derived ports are sometimes not available leading to the error "Address
#        already in use in ...". This manual effort should prevent that. It should likely be generalized and used
#        in the other fullstack tests as well.
my %ports      = (webui => Mojo::IOLoop::Server->generate_port, websocket => Mojo::IOLoop::Server->generate_port);
my $utils_mock = Test::MockModule->new('OpenQA::Utils');
$utils_mock->mock(
    service_port => sub {
        my ($service) = @_;
        my $port = $ports{$service};
        BAIL_OUT("Service_port was called for unexpected/unknown service $service") unless defined $port;
        note("Mocking service port for $service to be $port");
        return $port;
    });
note('Used ports: ' . dumper(\%ports));

# setup basedir, config dir and database
my $tempdir = setup_fullstack_temp_dir('scalability');
my $schema  = OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $workers = $schema->resultset('Workers');
my $jobs    = $schema->resultset('Jobs');

# create web UI and websocket server
my $web_socket_server_pid = create_websocket_server($ports{websocket}, 0, 1, 1);
my $webui_pid             = create_webapi($ports{webui}, sub { });

# prepare spawning workers
my $sharedir        = setup_share_dir($ENV{OPENQA_BASEDIR});
my $resultdir       = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
my $api_credentials = create_user_for_workers;
my $api_key         = $api_credentials->key;
my $api_secret      = $api_credentials->secret;
my $webui_host      = "http://localhost:$ports{webui}";
my $worker_path     = path($FindBin::Bin)->child('../script/worker');
my $isotovideo_path = path($FindBin::Bin)->child('dummy-isotovideo.sh');
my @worker_args     = (
    "--apikey=$api_key", "--apisecret=$api_secret", "--host=$webui_host", "--isotovideo=$isotovideo_path",
    '--verbose',         '--no-cleanup',
);
note("Share dir: $sharedir");
note("Result dir: $resultdir");

# spawn workers
note("Spawning $worker_count workers");
sub spawn_worker {
    my ($instance) = @_;

    note("Starting worker '$instance'");
    my $workerpid = fork();
    return $workerpid if $workerpid != 0;

    exec('perl', $worker_path, "--instance=$instance", @worker_args);
    die "failed to start worker $instance";
}
my %worker_ids;
my @worker_pids = map { spawn_worker($_) } (1 .. $worker_count);

# create jobs
note("Creating $job_count jobs");
sub log_jobs {
    my @job_info
      = map { sprintf("id: %s, state: %s, result: %s, reason: %s", $_->id, $_->state, $_->result, $_->reason // 'none') }
      $jobs->search({}, {order_by => 'id'});
    note("All jobs:\n - " . join("\n - ", @job_info));
}
my %job_ids;
my @job_settings = (
    BUILD   => '0048@0815',
    DISTRI  => 'opensuse',
    VERSION => 'Factory',
    FLAVOR  => 'tape',
    ARCH    => 'x86_64',
    MACHINE => 'xxx',
);
$job_ids{$jobs->create({@job_settings, TEST => "dummy-$_"})->id} = 1 for 1 .. $job_count;

my $seconds_to_wait_per_worker = 5.0;
my $seconds_to_wait_per_job    = 1.0;
my $polling_interval           = 0.1;
my $polling_tries_workers      = $seconds_to_wait_per_worker / $polling_interval * $worker_count;
my $polling_tries_jobs         = $seconds_to_wait_per_job / $polling_interval * $job_count;

subtest 'wait for workers to be idle' => sub {
    for my $try (1 .. $polling_tries_workers) {
        last if $workers->count == $worker_count;
        note("Waiting until all workers are registered, try $try");
        sleep $polling_interval;
    }
    is($workers->count, $worker_count, 'all workers registered');
    my @non_idle_workers;
    for my $worker ($workers->all) {
        $worker_ids{$worker->id} = 1;
        push(@non_idle_workers, $worker->id) if $worker->status ne 'idle';
    }
    ok(!@non_idle_workers, 'all workers idling') or diag explain \@non_idle_workers;
};

subtest 'assign and run jobs' => sub {
    my $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule;
    BAIL_OUT('Unable to assign jobs to (idling) workers') unless ref($allocated) eq 'ARRAY' && @$allocated > 0;

    my $remaining_jobs = $job_count - $worker_count;
    note("Assigned jobs: " . dumper($allocated));
    note('Remaining ' . ($remaining_jobs > 0 ? ('jobs: ' . $remaining_jobs) : ('workers: ' . -$remaining_jobs)));
    if ($remaining_jobs > 0) {
        is(scalar @$allocated, $worker_count, 'each worker has a job assigned');
    }
    elsif ($remaining_jobs < 0) {
        is(scalar @$allocated, $job_count, 'each job has a worker assigned');
    }
    else {
        is(scalar @$allocated, $job_count, 'all jobs assigned and all workers busy');
        my @allocated_job_ids    = map { $_->{job} } @$allocated;
        my @allocated_worker_ids = map { $_->{worker} } @$allocated;
        my @expected_job_ids     = map { int($_) } keys %job_ids;
        my @expected_worker_ids  = map { int($_) } keys %worker_ids;
        is_deeply([sort @allocated_job_ids],    [sort @expected_job_ids],    'all jobs allocated');
        is_deeply([sort @allocated_worker_ids], [sort @expected_worker_ids], 'all workers allocated');
    }
    for my $try (1 .. $polling_tries_jobs) {
        last if $jobs->search({state => DONE})->count == $job_count;
        if ($jobs->search({state => SCHEDULED})->count > $remaining_jobs) {
            note('At least one job has been set back to scheduled; aborting to wait until all jobs are done');
            last;
        }
        if ($remaining_jobs > 0) {
            note("Trying to assign remaining $remaining_jobs jobs");
            if (my $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule) {
                my $assigned_job_count = scalar @$allocated;
                $remaining_jobs -= $assigned_job_count;
                note("Assigned $assigned_job_count more jobs: " . dumper($allocated)) if $assigned_job_count > 0;
            }
        }
        note("Waiting until all jobs are done, try $try");
        sleep $polling_interval;
    }
    my $done   = is($jobs->search({state  => DONE})->count,   $job_count, 'all jobs done');
    my $passed = is($jobs->search({result => PASSED})->count, $job_count, 'all jobs passed');
    log_jobs unless $done && $passed;
};

subtest 'stop all workers' => sub {
    stop_service $_ for @worker_pids;
    my @non_offline_workers;
    for my $try (1 .. $polling_tries_workers) {
        @non_offline_workers = ();
        for my $worker ($workers->all) {
            push(@non_offline_workers, $worker->id) unless $worker->dead;
        }
        last unless @non_offline_workers;
        note("Waiting until all workers are offline, try $try");
        sleep $polling_interval;
    }
    ok(!@non_offline_workers, 'all workers offline') or diag explain \@non_offline_workers;
};

done_testing;

END {
    stop_service $_ for @worker_pids;
    stop_service $web_socket_server_pid;
    stop_service $webui_pid;
}
