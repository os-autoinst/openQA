#!/usr/bin/env perl
# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Test::Warnings ':report_warnings';
use Test::MockModule;
use Time::HiRes 'sleep';
use File::Path 'make_path';
use Scalar::Util 'looks_like_number';
use Mojo::File 'path';
use Mojo::Util 'dumper';
use IPC::Run qw(start);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Constants qw(WEBSOCKET_API_VERSION);
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Utils qw(service_port);
use OpenQA::Test::Database;
use OpenQA::Jobs::Constants;
use OpenQA::Log qw(setup_log);
use OpenQA::Test::Utils
  qw(mock_service_ports setup_mojo_app_with_default_worker_timeout),
  qw(create_user_for_workers create_webapi create_websocket_server),
  qw(stop_service setup_fullstack_temp_dir);
use OpenQA::Test::TimeLimit '20';
use OpenQA::Utils 'testcasedir';

BEGIN {
    # set defaults
    $ENV{SCALABILITY_TEST_JOB_COUNT} //= 5;
    $ENV{SCALABILITY_TEST_WORKER_COUNT} //= 2;
    $ENV{SCALABILITY_TEST_WITH_OFFLINE_WEBUI_HOST} //= 1;

    # allow the scheduler to assigns all jobs within one tick (needs to be in BEGIN block because the env variable
    # is assigned to constant)
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = $ENV{SCALABILITY_TEST_JOB_COUNT};
}

setup_mojo_app_with_default_worker_timeout;

# read number of workers to spawn from environment variable; skip test entirely if variable not present
# similar to other fullstack tests
my $worker_count = $ENV{SCALABILITY_TEST_WORKER_COUNT};
my $job_count = $ENV{SCALABILITY_TEST_JOB_COUNT} // $worker_count;
BAIL_OUT 'invalid SCALABILITY_TEST_WORKER_COUNT/SCALABILITY_TEST_JOB_COUNT'
  unless looks_like_number($worker_count) && looks_like_number($job_count) && $worker_count > 0 && $job_count > 0;
note("Running scalability test with $worker_count worker(s) and $job_count job(s).");
note('Set SCALABILITY_TEST_WORKER_COUNT/SCALABILITY_TEST_JOB_COUNT to adjust this.');

mock_service_ports;

# setup basedir, config dir and database
my $tempdir = setup_fullstack_temp_dir('scalability');
my $schema = OpenQA::Test::Database->new->create;
my $workers = $schema->resultset('Workers');
my $jobs = $schema->resultset('Jobs');

# create web UI and websocket server
my $web_socket_server = create_websocket_server(undef, 0, 1, 1, 1);
my $webui = create_webapi(undef, 1);

# prepare spawning workers
my $testsdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'share', 'tests')->make_path;
my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
my $api_credentials = create_user_for_workers;
my $api_key = $api_credentials->key;
my $api_secret = $api_credentials->secret;
my $webui_port = service_port 'webui';
my $webui_host = "http://localhost:$webui_port";
my $worker_path = path($FindBin::Bin)->child('../script/worker');
my $isotovideo_path = path($FindBin::Bin)->child('dummy-isotovideo.sh');
$webui_host .= " http://localhost:12345" if $ENV{SCALABILITY_TEST_WITH_OFFLINE_WEBUI_HOST};
my @worker_args = (
    "--apikey=$api_key", "--apisecret=$api_secret", "--host=$webui_host", "--isotovideo=$isotovideo_path",
    '--verbose', '--no-cleanup',
);
note("Tests dir: $testsdir");
note("Result dir: $resultdir");

# spawn workers
note("Spawning $worker_count workers");
sub spawn_worker {
    my ($instance) = @_;

    local $ENV{PERL5OPT} = '';    # uncoverable statement
    note("Starting worker '$instance'");    # uncoverable statement
    $0 = 'openqa-worker';    # uncoverable statement
    start ['perl', $worker_path, "--instance=$instance", @worker_args];    # uncoverable statement
}
my %worker_ids;
my @workers = map { spawn_worker($_) } (1 .. $worker_count);

# create jobs
note("Creating $job_count jobs");
sub log_jobs {
    # uncoverable sub only used in case of failures
    my @job_info
      # uncoverable statement count:1
      # uncoverable statement count:2
      = map { sprintf("id: %s, state: %s, result: %s, reason: %s", $_->id, $_->state, $_->result, $_->reason // 'none') }
      $jobs->search({}, {order_by => 'id'});
    # uncoverable statement
    diag("All jobs:\n - " . join("\n - ", @job_info));
}
my %job_ids;
my $distri = 'opensuse';
my $version = 'Factory';
my @job_settings = (
    BUILD => '0048@0815',
    DISTRI => $distri,
    VERSION => $version,
    FLAVOR => 'tape',
    ARCH => 'x86_64',
    MACHINE => 'xxx',
);
$job_ids{$jobs->create({@job_settings, TEST => "dummy-$_"})->id} = 1 for 1 .. $job_count;

# the casedir must exist before making symlink from casedir to the current working directory
my $casedir = testcasedir($distri, $version, undef);
path($casedir)->make_path unless -d $casedir;

my $seconds_to_wait_per_worker = 5.0;
my $seconds_to_wait_per_job = 2.5;
my $polling_interval = 0.1;
my $polling_tries_workers = $seconds_to_wait_per_worker / $polling_interval * $worker_count;
my $polling_tries_jobs = $seconds_to_wait_per_job / $polling_interval * $job_count;

subtest 'wait for workers to be idle' => sub {
    my @worker_search_args = ({'properties.key' => 'WEBSOCKET_API_VERSION'}, {join => 'properties'});
    for my $try (1 .. $polling_tries_workers) {
        last if $workers->search(@worker_search_args)->count == $worker_count;
        note("Waiting until all workers are registered, try $try");
        sleep $polling_interval;
    }
    is($workers->count, $worker_count, 'all workers registered');
    my @non_idle_workers;
    for my $worker ($workers->all) {
        $worker_ids{$worker->id} = 1;
        push(@non_idle_workers, $worker->info)
          if $worker->status ne 'idle' || ($worker->websocket_api_version || 0) != WEBSOCKET_API_VERSION;
    }
    ok(!@non_idle_workers, 'all workers idling') or diag explain \@non_idle_workers;
};

subtest 'assign and run jobs' => sub {
    my $scheduler = OpenQA::Scheduler::Model::Jobs->singleton;
    my $allocated = $scheduler->schedule;
    unless (ref($allocated) eq 'ARRAY' && @$allocated > 0) {
        diag explain 'Allocated: ', $allocated;    # uncoverable statement
        diag explain 'Scheduled: ', $scheduler->scheduled_jobs;    # uncoverable statement
        BAIL_OUT('Unable to assign jobs to (idling) workers');    # uncoverable statement
    }

    my $remaining_jobs = $job_count - $worker_count;
    note("Assigned jobs: " . dumper($allocated));
    note('Remaining ' . ($remaining_jobs > 0 ? ('jobs: ' . $remaining_jobs) : ('workers: ' . -$remaining_jobs)));
    if ($remaining_jobs > 0) {
        is(scalar @$allocated, $worker_count, 'each worker has a job assigned');
    }
    elsif ($remaining_jobs < 0) {
        # uncoverable statement only executed when there are more jobs than workers based config parameters
        is(scalar @$allocated, $job_count, 'each job has a worker assigned');
    }
    else {
        # uncoverable statement only executed when the number of workers is # jobs are equal based on config parameters
        is(scalar @$allocated, $job_count, 'all jobs assigned and all workers busy');
        # uncoverable statement count:1
        # uncoverable statement count:2
        my @allocated_job_ids = map { $_->{job} } @$allocated;
        # uncoverable statement count:1
        # uncoverable statement count:2
        my @allocated_worker_ids = map { $_->{worker} } @$allocated;
        # uncoverable statement count:1
        # uncoverable statement count:2
        my @expected_job_ids = map { int($_) } keys %job_ids;
        # uncoverable statement count:1
        # uncoverable statement count:2
        my @expected_worker_ids = map { int($_) } keys %worker_ids;
        # uncoverable statement
        is_deeply([sort @allocated_job_ids], [sort @expected_job_ids], 'all jobs allocated');
        # uncoverable statement
        is_deeply([sort @allocated_worker_ids], [sort @expected_worker_ids], 'all workers allocated');
    }
    for my $try (1 .. $polling_tries_jobs) {
        last if $jobs->search({state => DONE})->count == $job_count;
        if ($jobs->search({state => SCHEDULED})->count > $remaining_jobs) {
            # uncoverable statement
            note('At least one job has been set back to scheduled; aborting to wait until all jobs are done');
            last;    # uncoverable statement
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
    my $done = is($jobs->search({state => DONE})->count, $job_count, 'all jobs done');
    my $passed = is($jobs->search({result => PASSED})->count, $job_count, 'all jobs passed');
    log_jobs unless $done && $passed;
};

subtest 'stop all workers' => sub {
    stop_service $_ for @workers;
    my @non_offline_workers;
    for my $try (1 .. $polling_tries_workers) {
        @non_offline_workers = ();
        for my $worker ($workers->all) {
            push(@non_offline_workers, $worker->id) unless $worker->dead;
        }
        last unless @non_offline_workers;
        note("Waiting until all workers are offline, try $try");    # uncoverable statement
        sleep $polling_interval;    # uncoverable statement
    }
    ok(!@non_offline_workers, 'all workers offline') or diag explain \@non_offline_workers;
};

done_testing;

END {
    stop_service $_ for @workers;
    stop_service $web_socket_server;
    stop_service $webui;
}
