#!/usr/bin/env perl

# Copyright (C) 2014-2020 SUSE LLC
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

BEGIN {
    # require the scheduler to be fixed in its actions since tests depends on timing
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 10;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 2000;
    $ENV{FULLSTACK}                           = 1 if $ENV{SCHEDULER_FULLSTACK};
}

use IPC::Run qw(start);
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD DB_TIMESTAMP_ACCURACY);
use OpenQA::Scheduler::Client;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::MockModule;
use Mojo::IOLoop::Server;
use Mojo::File qw(path tempfile);
use Time::HiRes 'sleep';
use OpenQA::Test::Utils qw(
  setup_fullstack_temp_dir create_user_for_workers
  create_webapi wait_for_worker setup_share_dir create_websocket_server
  stop_service unstable_worker
  unresponsive_worker broken_worker rejective_worker
);
use Mojolicious;
use DateTime;

# treat this test like the fullstack test
plan skip_all => "set SCHEDULER_FULLSTACK=1 (be careful)" unless $ENV{SCHEDULER_FULLSTACK};

# setup directories and database
my $tempdir         = setup_fullstack_temp_dir('scheduler');
my $schema          = OpenQA::Test::Database->new->create;
my $api_credentials = create_user_for_workers;
my $api_key         = $api_credentials->key;
my $api_secret      = $api_credentials->secret;

# create web UI and websocket server
my $mojoport = $ENV{OPENQA_BASE_PORT} = Mojo::IOLoop::Server->generate_port();
my $ws       = create_websocket_server($mojoport + 1, 0, 1, 1);
my $webapi   = create_webapi($mojoport, sub { });
my @workers;

# setup share and result dir
my $sharedir  = setup_share_dir($ENV{OPENQA_BASEDIR});
my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir, "results directory created under $resultdir";

sub create_worker {
    my ($apikey, $apisecret, $host, $instance, $log) = @_;
    my @connect_args = ("--instance=${instance}", "--apikey=${apikey}", "--apisecret=${apisecret}", "--host=${host}");
    note("Starting standard worker. Instance: $instance for host $host");
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
    $_->update({t_updated => DateTime->from_epoch(epoch => time - WORKERS_CHECKER_THRESHOLD - DB_TIMESTAMP_ACCURACY)})
      for $schema->resultset("Workers")->all();
}

sub scheduler_step { OpenQA::Scheduler::Model::Jobs->singleton->schedule() }

subtest 'Scheduler worker job allocation' => sub {
    note('try to allocate to previous worker (supposed to fail)');
    my $allocated = scheduler_step();
    is @$allocated, 0;

    note('starting two workers');
    @workers = map { create_worker($api_key, $api_secret, "http://localhost:$mojoport", $_) } (1, 2);
    wait_for_worker($schema, 3);
    wait_for_worker($schema, 4);

    note('assigning one job to each worker');
    ($allocated) = scheduler_step();
    my $job_id1           = $allocated->[0]->{job};
    my $job_id2           = $allocated->[1]->{job};
    my $wr_id1            = $allocated->[0]->{worker};
    my $wr_id2            = $allocated->[1]->{worker};
    my $different_workers = isnt($wr_id1, $wr_id2, 'jobs dispatched to different workers');
    my $different_jobs    = isnt($job_id1, $job_id2, 'each of the two jobs allocated to one of the workers');
    diag explain $allocated unless $different_workers && $different_jobs;

    ($allocated) = scheduler_step();
    is @$allocated, 0;

    stop_workers;
    dead_workers($schema);
};

subtest 're-scheduling and incompletion of jobs when worker rejects jobs or goes offline' => sub {
    # avoid wasting time waiting for status updates
    my $web_ui_connection_mock = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
    $web_ui_connection_mock->redefine(_calculate_status_update_interval => .1);

    my $jobs   = $schema->resultset('Jobs');
    my @latest = $jobs->latest_jobs;
    shift(@latest)->auto_duplicate();

    # try to allocate to previous worker and fail!
    my ($allocated) = scheduler_step();
    is(@$allocated, 0, 'no jobs allocated');

    # simulate a worker in broken state; it will register itself but declare itself as broken
    @workers = broken_worker($api_key, $api_secret, "http://localhost:$mojoport", 3, 'out of order');
    wait_for_worker($schema, 5);
    $allocated = scheduler_step();
    is(@$allocated, 0, 'scheduler does not consider broken worker for allocating job');
    stop_workers;
    dead_workers($schema);

    # simulate a worker in idle state that rejects all jobs assigned to it
    @workers = rejective_worker($api_key, $api_secret, "http://localhost:$mojoport", 3, 'rejection reason');
    wait_for_worker($schema, 5);

    note('waiting for job to be assigned and set back to re-scheduled');
    $allocated = scheduler_step();
    is(@$allocated, 1, 'one job allocated')
      and is(@{$allocated}[0]->{job},    99982, 'right job allocated')
      and is(@{$allocated}[0]->{worker}, 5,     'job allocated to expected worker');
    my $job_assigned  = 0;
    my $job_scheduled = 0;
    for (0 .. 100) {
        my $job_state = $jobs->find(99982)->state;
        if ($job_state eq OpenQA::Jobs::Constants::ASSIGNED) {
            note('job is assigned') unless $job_assigned;
            $job_assigned = 1;
        }
        elsif ($job_state eq OpenQA::Jobs::Constants::SCHEDULED) {
            $job_scheduled = 1;
            last;
        }
        sleep .2;
    }
    ok($job_scheduled, 'assigned job set back to scheduled if worker reports back again but has abandoned the job');
    stop_workers;
    dead_workers($schema);

    # start an unstable worker; it will register itself but ignore any job assignment (also not explicitely reject
    # assignments)
    @workers = unstable_worker($api_key, $api_secret, "http://localhost:$mojoport", 3, -1);
    wait_for_worker($schema, 5);

    ($allocated) = scheduler_step();
    is(@$allocated, 1, 'one job allocated')
      and is(@{$allocated}[0]->{job},    99982, 'right job allocated')
      and is(@{$allocated}[0]->{worker}, 5,     'job allocated to expected worker');

    # kill the worker but assume the job has been actually started and is running
    stop_workers;
    $jobs->find(99982)->update({state => OpenQA::Jobs::Constants::RUNNING});

    @workers = unstable_worker($api_key, $api_secret, "http://localhost:$mojoport", 3, -1);
    wait_for_worker($schema, 5);

    note('waiting for job to be incompleted');
    for (0 .. 100) {
        last if $jobs->find(99982)->state eq OpenQA::Jobs::Constants::DONE;
        sleep .2;
    }

    my $job = $jobs->find(99982);
    is $job->state, OpenQA::Jobs::Constants::DONE,
      'running job set to done if its worker re-connects claiming not to work on it anymore';
    is $job->result, OpenQA::Jobs::Constants::INCOMPLETE,
      'running job incompleted if its worker re-connects claiming not to work on it anymore';
    like $job->reason, qr/abandoned: associated worker .+:\d+ re-connected but abandoned the job/, 'reason is set';

    stop_workers;
    dead_workers($schema);
};

subtest 'Simulation of heavy unstable load' => sub {
    dead_workers($schema);
    my @duplicated;

    # duplicate latest jobs ignoring failures
    for my $job ($schema->resultset('Jobs')->latest_jobs) {
        my $duplicate = $job->auto_duplicate;
        push(@duplicated, $duplicate) if defined $duplicate;
    }

    @workers = map { unresponsive_worker($api_key, $api_secret, "http://localhost:$mojoport", $_) } (1 .. 50);
    my $i = 4;
    wait_for_worker($schema, ++$i) for 1 .. 10;

    my $allocated = scheduler_step();    # Will try to allocate to previous worker and fail!
    is(@$allocated, 10, "Allocated maximum number of jobs that could have been allocated") or die;
    my %jobs;
    my %w;
    foreach my $j (@$allocated) {
        ok !$jobs{$j->{job}}, "Job (" . $j->{job} . ") allocated only once";
        ok !$w{$j->{worker}}, "Worker (" . $j->{worker} . ") used only once";
        $w{$j->{worker}}++;
        $jobs{$j->{job}}++;
    }

    for my $dup (@duplicated) {
        for (0 .. 100) {
            last if $dup->state eq OpenQA::Jobs::Constants::SCHEDULED;
            sleep 2;
        }
        is $dup->state, OpenQA::Jobs::Constants::SCHEDULED, "Job(" . $dup->id . ") back in scheduled state";
    }
    stop_workers;
    dead_workers($schema);

    @workers = map { unstable_worker($api_key, $api_secret, "http://localhost:$mojoport", $_, 3) } (1 .. 30);
    $i       = 5;
    wait_for_worker($schema, ++$i) for 0 .. 12;

    $allocated = scheduler_step();    # Will try to allocate to previous worker and fail!
    is @$allocated, 0, "All failed allocation on second step - workers were killed";
    for my $dup (@duplicated) {
        for (0 .. 100) {
            last if $dup->state eq OpenQA::Jobs::Constants::SCHEDULED;
            sleep 2;
        }
        is $dup->state, OpenQA::Jobs::Constants::SCHEDULED, "Job(" . $dup->id . ") is still in scheduled state";
    }

    stop_workers;
};

subtest 'Websocket server - close connection test' => sub {
    stop_service($ws);

    local $ENV{OPENQA_LOGFILE};
    local $ENV{MOJO_LOG_LEVEL};

    my $log;
    # create unstable ws
    $ws      = create_websocket_server($mojoport + 1, 1, 0);
    @workers = create_worker($api_key, $api_secret, "http://localhost:$mojoport", 2, \$log);

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
};

END {
    stop_workers;
    stop_service($_, 1) for ($ws, $webapi);
}

done_testing;
