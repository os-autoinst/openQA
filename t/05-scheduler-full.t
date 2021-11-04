#!/usr/bin/env perl

# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN {
    # require the scheduler to be fixed in its actions since tests depends on timing
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 10;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} = 100;
}

use Test::MockModule;
use DateTime;
use File::Which;
use IPC::Run qw(start);
use Mojolicious;
use Mojo::IOLoop::Server;
use Mojo::File qw(path tempfile);
use Time::HiRes 'sleep';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler::Client;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(
  mock_service_ports setup_mojo_app_with_default_worker_timeout
  setup_fullstack_temp_dir create_user_for_workers
  create_webapi setup_share_dir create_websocket_server
  stop_service unstable_worker
  unresponsive_worker broken_worker rejective_worker
  wait_for
);
use OpenQA::Test::TimeLimit '150';

# treat this test like the fullstack test
plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};

setup_mojo_app_with_default_worker_timeout;

# setup directories and database
my $tempdir = setup_fullstack_temp_dir('scheduler');
my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl');
my $api_credentials = create_user_for_workers;
my $api_key = $api_credentials->key;
my $api_secret = $api_credentials->secret;

# create web UI and websocket server
mock_service_ports;
my $mojoport = service_port 'webui';
my $ws = create_websocket_server(undef, 0, 1, 1);
my $webapi = create_webapi($mojoport, sub { });
my @workers;

# setup share and result dir
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});
my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir, "results directory created under $resultdir";

sub create_worker {
    my ($apikey, $apisecret, $host, $instance, $log) = @_;
    my @connect_args = ("--instance=${instance}", "--apikey=${apikey}", "--apisecret=${apisecret}", "--host=${host}");
    note "Starting standard worker. Instance: $instance for host $host";
    # save testing time as we do not test a webUI host being down for
    # multiple minutes
    $ENV{OPENQA_WORKER_CONNECT_RETRIES} = 1;
    my @cmd = qw(perl ./script/worker --isotovideo=../os-autoinst/isotovideo --verbose);
    push @cmd, @connect_args;
    return $log ? start \@cmd, \undef, '>&', $log : start \@cmd;
}

sub stop_workers { stop_service($_, 1) for @workers }

sub dead_workers {
    my $schema = shift;
    $_->update({t_seen => DateTime->from_epoch(epoch => time - DEFAULT_WORKER_TIMEOUT - DB_TIMESTAMP_ACCURACY)})
      for $schema->resultset("Workers")->all();
}

sub wait_for_worker {
    my ($schema, $id) = @_;

    note "Waiting for worker with ID $id";    # uncoverable statement
    for (0 .. 40) {
        my $worker = $schema->resultset('Workers')->find($id);
        return undef if defined $worker && !$worker->dead;
        sleep .5;
    }
    note "No worker with ID $id active";    # uncoverable statement
}

sub scheduler_step { OpenQA::Scheduler::Model::Jobs->singleton->schedule() }

my $worker_settings = [$api_key, $api_secret, "http://localhost:$mojoport"];

subtest 'Scheduler worker job allocation' => sub {
    note 'try to allocate to previous worker (supposed to fail)';
    my $allocated = scheduler_step();
    is @$allocated, 0, 'no jobs allocated for no active workers';

    note 'starting two workers';
    @workers = map { create_worker(@$worker_settings, $_) } (1, 2);
    wait_for_worker($schema, 3);
    wait_for_worker($schema, 4);

    note 'assigning one job to each worker';
    $allocated = scheduler_step();
    my $job_id1 = $allocated->[0]->{job};
    my $job_id2 = $allocated->[1]->{job};
    my $wr_id1 = $allocated->[0]->{worker};
    my $wr_id2 = $allocated->[1]->{worker};
    my $different_workers = isnt($wr_id1, $wr_id2, 'jobs dispatched to different workers');
    my $different_jobs = isnt($job_id1, $job_id2, 'each of the two jobs allocated to one of the workers');
    diag explain $allocated unless $different_workers && $different_jobs;

    $allocated = scheduler_step();
    is @$allocated, 0, 'no more jobs need to be allocated';

    stop_workers;
    dead_workers($schema);
};

subtest 're-scheduling and incompletion of jobs when worker rejects jobs or goes offline' => sub {
    # avoid wasting time waiting for status updates
    my $web_ui_connection_mock = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
    $web_ui_connection_mock->redefine(_calculate_status_update_interval => .1);

    my $jobs = $schema->resultset('Jobs');
    my @latest = $jobs->latest_jobs;
    shift(@latest)->auto_duplicate();

    # try to allocate to previous worker and fail!
    my $allocated = scheduler_step();
    is @$allocated, 0, 'no jobs can be allocated to previous workers';

    # simulate a worker in broken state; it will register itself but declare itself as broken
    @workers = broken_worker(@$worker_settings, 3, 'out of order');
    wait_for_worker($schema, 5);
    $allocated = scheduler_step();
    is @$allocated, 0, 'scheduler does not consider broken worker for allocating job';
    stop_workers;
    dead_workers($schema);

    # simulate a worker in idle state that rejects all jobs assigned to it
    @workers = rejective_worker(@$worker_settings, 3, 'rejection reason');
    wait_for_worker($schema, 5);

    note 'waiting for job to be assigned and set back to re-scheduled';
    # the loop is needed as the scheduler sometimes needs a second
    # cycle before the worker is seen as unusable
    for (1 .. 2) {
        $allocated = scheduler_step();
        last if $allocated && @$allocated >= 1;
        note "scheduler could not yet assign to rejective worker, try: $_";    # uncoverable statement
    }
    is @$allocated, 1, 'one job allocated'
      and is @{$allocated}[0]->{job}, 99982, 'right job allocated'
      and is @{$allocated}[0]->{worker}, 5, 'job allocated to expected worker';
    my $job_assigned = 0;
    my $job_scheduled = 0;
    for (0 .. 100) {
        my $job_state = $jobs->find(99982)->state;
        if ($job_state eq ASSIGNED) {
            note 'job is assigned' unless $job_assigned;    # uncoverable statement
            $job_assigned = 1;    # uncoverable statement
        }
        elsif ($job_state eq SCHEDULED) {
            $job_scheduled = 1;
            last;
        }
        sleep .2;    # uncoverable statement
    }
    ok $job_scheduled, 'assigned job set back to scheduled if worker reports back again but has abandoned the job';
    stop_workers;
    dead_workers($schema);

    # start an unstable worker; it will register itself but ignore any job assignment (also not explicitly reject
    # assignments)
    @workers = unstable_worker(@$worker_settings, 3, -1);
    wait_for_worker($schema, 5);
    for (1 .. 2) {
        $allocated = scheduler_step();
        last if $allocated && @$allocated >= 1;
        note "scheduler could not yet assign to broken worker, try: $_";    # uncoverable statement
    }
    is @$allocated, 1, 'one job allocated'
      and is @{$allocated}[0]->{job}, 99982, 'right job allocated'
      and is @{$allocated}[0]->{worker}, 5, 'job allocated to expected worker';

    # kill the worker but assume the job has been actually started and is running
    # note: Also setting back assigned_worker_id and result because the worker might have actually picked up the job.
    stop_workers;
    $jobs->find(99982)->update({assigned_worker_id => 5, state => RUNNING, result => NONE});

    @workers = unstable_worker(@$worker_settings, 3, -1);
    wait_for_worker($schema, 5);
    wait_for { $jobs->find(99982)->state eq DONE } 'job 99982 is incompleted', {timeout => 20};

    my $job = $jobs->find(99982);
    is $job->state, DONE, 'running job set to done if its worker re-connects claiming not to work on it anymore';
    is $job->result, INCOMPLETE, 'running job incompleted if its worker re-connects claiming not to work on it anymore';
    like $job->reason, qr/abandoned: associated worker .+:\d+ re-connected but abandoned the job/, 'reason is set';

    stop_workers;
    dead_workers($schema);
};

subtest 'Simulation of heavy unstable load' => sub {
    dead_workers($schema);

    # duplicate latest jobs ignoring failures
    my @duplicated = map { my $dup = $_->auto_duplicate; ref $dup ? $dup : () } $schema->resultset('Jobs')->latest_jobs;
    my $nr = $ENV{OPENQA_SCHEDULER_TEST_UNRESPONSIVE_COUNT} // 50;
    @workers = map { unresponsive_worker(@$worker_settings, $_) } (1 .. $nr);
    my $i = 2;
    wait_for_worker($schema, ++$i) for 1 .. $nr;

    my $allocated = scheduler_step();    # Will try to allocate to previous worker and fail!
    is @$allocated, 10, 'Allocated maximum number of jobs that could have been allocated' or die;
    my %jobs;
    my %w;
    foreach my $j (@$allocated) {
        ok !$jobs{$j->{job}}, "Job ($j->{job}) allocated only once";
        ok !$w{$j->{worker}}, "Worker ($j->{worker}) used only once";
        $w{$j->{worker}}++;
        $jobs{$j->{job}}++;
    }

    for my $dup (@duplicated) {
        for (0 .. 2000) {
            last if $dup->state eq SCHEDULED;
            sleep .1;    # uncoverable statement
        }
        is $dup->state, SCHEDULED, "Job(" . $dup->id . ") back in scheduled state";
    }
    stop_workers;
    dead_workers($schema);

    my $unstable_workers = $ENV{OPENQA_SCHEDULER_TEST_UNSTABLE_COUNT} // 30;
    @workers = map { unstable_worker(@$worker_settings, $_, 3) } (1 .. $unstable_workers);
    $i = 5;
    wait_for_worker($schema, ++$i) for 0 .. 12;

    $allocated = scheduler_step();    # Will try to allocate to previous worker and fail!
    is @$allocated, 0, 'All failed allocation on second step - workers were killed';
    for my $dup (@duplicated) {
        for (0 .. 2000) {
            last if $dup->state eq SCHEDULED;
            sleep .1;    # uncoverable statement
        }
        is $dup->state, SCHEDULED, "Job(" . $dup->id . ") is still in scheduled state";
    }

    stop_workers;
};

subtest 'Websocket server - close connection test' => sub {
    stop_service($ws);

    local $ENV{OPENQA_LOGFILE};
    local $ENV{MOJO_LOG_LEVEL};
    local $ENV{OPENQA_WORKER_CONNECT_INTERVAL} = 0;

    my $log;
    # create unstable ws
    $ws = create_websocket_server(undef, 1, 0);
    @workers = create_worker(@$worker_settings, 2, \$log);

    my $found_connection_closed_in_log = 0;
    for my $attempt (0 .. 300) {
        $log = '';
        $workers[0]->pump;
        note "worker out: $log";
        if ($log =~ qr/.*Websocket connection to .* finished by remote side with code 1008.*/) {
            $found_connection_closed_in_log = 1;
            last;
        }
    }
    is $found_connection_closed_in_log, 1, 'closed ws connection logged by worker';
    stop_workers;
    stop_service($ws);
};

END {
    stop_workers;
    stop_service($_, 1) for ($ws, $webapi);
    if (which 'ps') {
        $ENV{CI} and note "### all processes: " . qx{ps auxf} . "\n";
        note "### processes in tree: " . qx{ps Tf} . "\n";
    }
}

done_testing;
