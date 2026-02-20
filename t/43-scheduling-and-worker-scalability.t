#!/usr/bin/env perl
# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Time::HiRes 'sleep';
use File::Path 'make_path';
use Scalar::Util 'looks_like_number';
use List::Util qw(min max);
use Mojo::File qw(path tempfile);
use Mojo::Util qw(dumper scope_guard);
use IPC::Run qw(start);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Constants qw(WEBSOCKET_API_VERSION);
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Utils qw(service_port);
require OpenQA::Test::Database;
use OpenQA::Jobs::Constants;
use OpenQA::Log qw(setup_log);
use OpenQA::Test::Utils qw(
  setup_mojo_app_with_default_worker_timeout
  create_user_for_workers create_webapi create_websocket_server
  stop_service setup_fullstack_temp_dir simulate_load);
use OpenQA::Test::TimeLimit '20';
use OpenQA::Utils 'testcasedir';

BEGIN {
    # set defaults
    $ENV{SCALABILITY_TEST_WORKER_COUNT} //= 5;
    $ENV{SCALABILITY_TEST_WITH_OFFLINE_WEBUI_HOST} //= 1;
}

setup_mojo_app_with_default_worker_timeout;
OpenQA::Setup::read_config(my $app = OpenQA::App->singleton);

my $load_avg_file = simulate_load('0.93 0.95 3.25 2/2207 1212', '43-scheduling-and-worker-scalability');

# read number of workers to create
my $worker_count = $ENV{SCALABILITY_TEST_WORKER_COUNT};
BAIL_OUT 'invalid SCALABILITY_TEST_WORKER_COUNT' unless looks_like_number($worker_count) && $worker_count > 0;

# determine job counts for three scenarios: worker count > job count, worker count = job count, worker count < job count
my @job_counts = sort { $a <=> $b } grep { $_ > 0 } ($worker_count - 2, $worker_count, $worker_count + 2);
my %seen;
@job_counts = grep { !$seen{$_}++ } @job_counts;

note("Running scalability tests with $worker_count worker(s) and job counts: @job_counts.");

# setup basedir, config dir
my $tempdir = setup_fullstack_temp_dir('scalability');
chdir $tempdir;
my $guard = scope_guard sub { chdir $FindBin::Bin };

my $worker_path = path($FindBin::Bin)->child('../script/worker');
my $isotovideo_path = path($FindBin::Bin)->child('dummy-isotovideo.sh');

sub spawn_worker ($instance, $api_key, $api_secret, $webui_host) {
    local $ENV{PERL5OPT} = '';    # uncoverable statement
    note("Starting worker '$instance'");    # uncoverable statement
    $0 = 'openqa-worker';    # uncoverable statement
    my @worker_args = (
        "--apikey=$api_key", "--apisecret=$api_secret", "--host=$webui_host", "--isotovideo=$isotovideo_path",
        '--verbose', '--no-cleanup',
    );
    start ['perl', $worker_path, "--instance=$instance", @worker_args];    # uncoverable statement
}

# configure websocket server to apply SCALABILITY_TEST_WORKER_LIMIT
my $worker_limit = $ENV{SCALABILITY_TEST_WORKER_LIMIT} // 100;
my $web_socket_server_mock = Test::MockModule->new('OpenQA::WebSockets');
my $configure_web_socket_server = sub ($self, @args) {
    my $original_function = $web_socket_server_mock->original('_setup');
    my $original_return_value = $original_function->($self, @args);
    $self->config->{misc_limits}->{max_online_workers} = $worker_limit;
    return $original_return_value;
};
$web_socket_server_mock->redefine(_setup => $configure_web_socket_server);
$configure_web_socket_server->($app);    # invoke this function here for the sake of tracking coverage

my @workers;
my ($web_socket_server, $webui);
for my $job_count (@job_counts) {
    subtest "Scalability test with $worker_count worker(s) and $job_count job(s)" => sub {
        # ensure fresh database for each scenario
        my $schema = OpenQA::Test::Database->new->create;
        my $workers_rs = $schema->resultset('Workers');
        my $jobs_rs = $schema->resultset('Jobs');

        # ensure the scheduler can assign all jobs within one tick
        local $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = $job_count;

        # create web UI and websocket server for this scenario
        $web_socket_server = create_websocket_server(undef, 0, 1, 1);
        $webui = create_webapi(undef, 1);

        # prepare spawning workers
        my $api_credentials = create_user_for_workers;
        my $api_key = $api_credentials->key;
        my $api_secret = $api_credentials->secret;
        my $webui_port = service_port 'webui';
        my $webui_host = "http://localhost:$webui_port";
        $webui_host .= ' http://localhost:12345' if $ENV{SCALABILITY_TEST_WITH_OFFLINE_WEBUI_HOST};

        my $log_jobs = sub {
            # uncoverable sub only used in case of failures
            my @job_info
              # uncoverable statement
              = map {
                # uncoverable statement
                sprintf('id: %s, state: %s, result: %s, reason: %s',
                    $_->id, $_->state, $_->result, $_->reason // 'none')
              } $jobs_rs->search({}, {order_by => 'id'});
            # uncoverable statement
            diag("All jobs:\n - " . join("\n - ", @job_info));
        };

        # spawn workers
        note("Spawning $worker_count workers");
        @workers = map { spawn_worker($_, $api_key, $api_secret, $webui_host) } (1 .. $worker_count);

        # create jobs
        note("Creating $job_count jobs");
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
        $jobs_rs->create({@job_settings, TEST => "dummy-$_"}) for 1 .. $job_count;

        # the casedir must exist before making symlink from casedir to the current working directory
        my $casedir = testcasedir($distri, $version, undef);
        path($casedir)->make_path unless -d $casedir;

        my $seconds_to_wait_per_worker = 5.0;
        my $seconds_to_wait_per_job = 2.5;
        my $polling_interval = 0.1;
        my $polling_tries_workers = $seconds_to_wait_per_worker / $polling_interval * $worker_count;
        my $polling_tries_jobs = $seconds_to_wait_per_job / $polling_interval * $job_count;

        subtest 'wait for workers to be idle' => sub {
            # wait for all workers to register, have correct API version and be idle
            # this ensures they are fully visible to the scheduler
            my $actual_count = 0;
            for my $try (1 .. $polling_tries_workers) {
                my @idle
                  = grep { $_->status eq 'idle' && ($_->websocket_api_version || 0) == WEBSOCKET_API_VERSION }
                  $workers_rs->all;
                $actual_count = scalar @idle;
                last if $actual_count == $worker_count;
                note("Waiting until all workers are registered and idle, try $try");    # uncoverable statement
                sleep $polling_interval;    # uncoverable statement
            }
            is $actual_count, $worker_count, 'all workers registered and idle';

            # check that no workers are in unexpected offline/error states
            my @non_idle_workers;
            for my $worker ($workers_rs->all) {
                my $is_idle = $worker->status eq 'idle';
                push(@non_idle_workers, $worker->info)    # uncoverable statement
                  if !$is_idle || ($worker->websocket_api_version || 0) != WEBSOCKET_API_VERSION;
            }
            is scalar @non_idle_workers, 0, 'all workers idling' or always_explain \@non_idle_workers;
        };

        subtest 'assign and run jobs' => sub {
            my $scheduler = OpenQA::Scheduler::Model::Jobs->singleton;

            # ensure the scheduler also sees them as free
            for my $try (1 .. $polling_tries_workers) {
                last if scalar @{OpenQA::Scheduler::Model::Jobs::determine_free_workers()} == $worker_count;
                sleep $polling_interval;    # uncoverable statement
            }

            # retry scheduling until all workers have a job assigned (or all jobs are assigned)
            my $expected_allocated = min($worker_count, $job_count);
            for my $try (1 .. $polling_tries_workers) {
                $scheduler->schedule;
                last
                  if $jobs_rs->search({state => {-in => [ASSIGNED, SETUP, RUNNING, DONE]}})->count
                  >= $expected_allocated;
                sleep $polling_interval;    # uncoverable statement
            }

            my $allocated_count = $jobs_rs->search({state => {-in => [ASSIGNED, SETUP, RUNNING, DONE]}})->count;
            ok($allocated_count >= $expected_allocated, 'all workers have a job or all jobs assigned')
              or diag("Allocated count: $allocated_count, expected at least: $expected_allocated");

            my $remaining_jobs = $job_count - $worker_count;
            note(
                'Remaining ' . ($remaining_jobs > 0 ? ('jobs: ' . $remaining_jobs) : ('workers: ' . -$remaining_jobs)));

            for my $try (1 .. $polling_tries_jobs) {
                my $done_count = $jobs_rs->search({state => DONE})->count;
                last if $done_count == $job_count;
                my $scheduled_count = $jobs_rs->search({state => SCHEDULED})->count;
                if ($scheduled_count > 0) {
                    note("Trying to assign $scheduled_count scheduled jobs");    # uncoverable statement
                    OpenQA::Scheduler::Model::Jobs->singleton->schedule;    # uncoverable statement
                }
                note("Waiting until all jobs are done ($done_count/$job_count), try $try");
                sleep $polling_interval;    # uncoverable statement
            }
            my $done = is($jobs_rs->search({state => DONE})->count, $job_count, 'all jobs done');
            my $passed = is($jobs_rs->search({result => PASSED})->count, $job_count, 'all jobs passed');
            $log_jobs->() unless $done && $passed;
        };

        subtest 'stop all workers' => sub {
            stop_service $_ for @workers;
            @workers = ();
            my @non_offline_workers;
            for my $try (1 .. $polling_tries_workers) {
                @non_offline_workers = ();
                for my $worker ($workers_rs->all) {
                    push(@non_offline_workers, $worker->id) unless $worker->dead;
                }
                last unless @non_offline_workers;
                note("Waiting until all workers are offline, try $try");    # uncoverable statement
                sleep $polling_interval;    # uncoverable statement
            }
            ok(!@non_offline_workers, 'all workers offline') or always_explain \@non_offline_workers;
        };

        stop_service $web_socket_server;
        stop_service $webui;
        undef $web_socket_server;
        undef $webui;
    };
}

done_testing;

END {
    stop_service $_ for @workers;
    stop_service $web_socket_server if $web_socket_server;
    stop_service $webui if $webui;
}
