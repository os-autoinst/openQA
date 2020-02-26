#!/usr/bin/env perl -w

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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use Mojo::File qw(path tempdir);

my $tempdir;
BEGIN {
    use FindBin;
    $tempdir             = tempdir;
    $ENV{OPENQA_BASEDIR} = $tempdir->child('t', 'scheduler');
    $ENV{OPENQA_CONFIG}  = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 10;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 2000;
    $ENV{FULLSTACK}                           = 1 if $ENV{SCHEDULER_FULLSTACK};
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
}

use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler::Client;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Worker::WebUIConnection;
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::MockModule;
use Mojo::IOLoop::Server;
use Mojo::File 'tempfile';
use Time::HiRes 'sleep';
use OpenQA::Test::Utils qw(
  create_webapi wait_for_worker setup_share_dir
  create_websocket_server create_scheduler
  kill_service unstable_worker client_output unresponsive_worker
);
use Mojolicious;
use File::Path qw(make_path remove_tree);
use DateTime;
# This test has to be treated like fullstack.
plan skip_all => "set SCHEDULER_FULLSTACK=1 (be careful)" unless $ENV{SCHEDULER_FULLSTACK};

init_db();
my $schema = OpenQA::Test::Database->new->create(skip_schema => 1);

# Create webapi and websocket server services
my $mojoport = Mojo::IOLoop::Server->generate_port();
my $wspid    = create_websocket_server($mojoport + 1, 0, 1, 1);
my $webapi   = create_webapi($mojoport, sub { });

# Setup needed files for workers.

my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir, "results directory created under $resultdir";

my $k = $schema->resultset("ApiKeys")->create({user_id => "99903"});

sub create_worker {
    my ($apikey, $apisecret, $host, $instance, $log) = @_;
    my $connect_args = "--instance=${instance} --apikey=${apikey} --apisecret=${apisecret} --host=${host}";
    note("Starting standard worker. Instance: $instance for host $host");

    my $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker $connect_args --isotovideo=../os-autoinst/isotovideo --verbose"
              . (defined $log ? " 2>&1 > $log" : ""));
        die "FAILED TO START WORKER";
    }
    return defined $log ? `pgrep -P $workerpid` : $workerpid;
}

subtest 'Scheduler worker job allocation' => sub {
    note('try to allocate to previous worker (supposed to fail)');
    my $allocated = scheduler_step();
    is @$allocated, 0;

    note('starting two workers');
    my $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);
    my $w2_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 2);
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

    kill_service($_, 1) for ($w1_pid, $w2_pid);
    dead_workers($schema);
};

subtest 're-scheduling and incompletion of jobs when worker is unresponsive or crashes completely' => sub {
    # avoid wasting time waiting for status updates
    my $web_ui_connection_mock = Test::MockModule->new('OpenQA::Worker::WebUIConnection');
    $web_ui_connection_mock->mock(_calculate_status_update_interval => .1);

    my $jobs   = $schema->resultset('Jobs');
    my @latest = $jobs->latest_jobs;
    shift(@latest)->auto_duplicate();

    # try to allocate to previous worker and fail!
    my ($allocated) = scheduler_step();

    # simulate unresponsive worker which will register itself but not grab any jobs
    my $unstable_w_pid = unresponsive_worker($k->key, $k->secret, "http://localhost:$mojoport", 3);
    wait_for_worker($schema, 5);

    note('waiting for job to be assigned and set back to re-scheduled');
    $allocated = scheduler_step();
    is(@$allocated,                1,     'one job allocated');
    is(@{$allocated}[0]->{job},    99982, 'right job allocated');
    is(@{$allocated}[0]->{worker}, 5,     'job allocated to expected worker');
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
    kill_service($unstable_w_pid, 1);

    # start unstable worker again
    $unstable_w_pid = unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", 3, -1);
    wait_for_worker($schema, 5);

    ($allocated) = scheduler_step();
    is(@$allocated,                1,     'one job allocated');
    is(@{$allocated}[0]->{job},    99982, 'right job allocated');
    is(@{$allocated}[0]->{worker}, 5,     'job allocated to expected worker');

    # kill the worker but assume the job has been actually started and is running
    kill_service($unstable_w_pid, 1);
    $jobs->find(99982)->update({state => OpenQA::Jobs::Constants::RUNNING});

    $unstable_w_pid = unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", 3, -1);
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
    is $job->reason, 'abandoned: associated worker re-connected but abandoned the job', 'reason is set';

    kill_service($unstable_w_pid, 1);
    dead_workers($schema);
};

subtest 'Simulation of heavy unstable load' => sub {
    my $allocated;
    my @workers;
    dead_workers($schema);
    my @duplicated;

    # duplicate latest jobs ignoring failures
    for my $job ($schema->resultset('Jobs')->latest_jobs) {
        my $duplicate = $job->auto_duplicate;
        push(@duplicated, $duplicate) if defined $duplicate;
    }

    push(@workers, unresponsive_worker($k->key, $k->secret, "http://localhost:$mojoport", $_)) for (1 .. 50);
    my $i = 4;
    wait_for_worker($schema, ++$i) for 1 .. 10;

    ($allocated) = scheduler_step();    # Will try to allocate to previous worker and fail!
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
    kill_service($_, 1) for @workers;
    dead_workers($schema);

    @workers = ();

    push(@workers, unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", $_, 3)) for (1 .. 30);
    $i = 5;
    wait_for_worker($schema, ++$i) for 0 .. 12;

    ($allocated) = scheduler_step();    # Will try to allocate to previous worker and fail!
    is @$allocated, 0, "All failed allocation on second step - workers were killed";
    for my $dup (@duplicated) {
        for (0 .. 100) {
            last if $dup->state eq OpenQA::Jobs::Constants::SCHEDULED;
            sleep 2;
        }
        is $dup->state, OpenQA::Jobs::Constants::SCHEDULED, "Job(" . $dup->id . ") is still in scheduled state";
    }

    kill_service($_, 1) for @workers;
};

subtest 'Websocket server - close connection test' => sub {
    kill_service($wspid);

    local $ENV{OPENQA_LOGFILE};
    local $ENV{MOJO_LOG_LEVEL};

    my $log_file        = tempfile;
    my $unstable_ws_pid = create_websocket_server($mojoport + 1, 1, 0);
    my $w2_pid          = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 2, $log_file);

    my $found_connection_closed_in_log = 0;
    my $log_file_content               = '';
    for (my $attempt = 0; $attempt < 300; ++$attempt) {
        $log_file_content = $log_file->slurp;
        if ($log_file_content =~ qr/.*Websocket connection to .* finished by remote side with code 1008.*/) {
            $found_connection_closed_in_log = 1;
            last;
        }
        sleep 1;
    }

    is($found_connection_closed_in_log, 1, 'closed ws connection logged by worker');
    kill_service($_) for ($unstable_ws_pid, $w2_pid);
    dead_workers($schema);

    if (!$found_connection_closed_in_log) {
        note('worker log file contained:');
        note($log_file_content);
    }
};

kill_service($_) for ($wspid, $webapi);

sub dead_workers {
    my $schema = shift;
    $_->update({t_updated => DateTime->from_epoch(epoch => time - 10200)}) for $schema->resultset("Workers")->all();
}

sub range_ok {
    my ($tick, $started, $fired) = @_;
    my $step       = 1000;
    my $low_limit  = $tick - $step;
    my $high_limit = $tick + $step;
    my $delta      = $fired - $started;
    ok(in_range($delta, $low_limit, $high_limit),
        "timeout in range $low_limit->$high_limit (setted tick $tick, real tick occurred at $delta)");
}

sub scheduler_step { OpenQA::Scheduler::Model::Jobs->singleton->schedule() }

sub get_scheduler_tick { shift->{tick} }

sub init_db {
    # Setup test DB
    path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string;
    ok -e path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->child("db.lock");
    ok(open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string));
    print $conf <<"EOC";
  [production]
  dsn = $ENV{TEST_PG}
EOC
    close($conf);
    # drop the schema from the existant database
    my $dbh = DBI->connect($ENV{TEST_PG});
    $dbh->do('SET client_min_messages TO WARNING;');
    $dbh->do('drop schema if exists public cascade;');
    $dbh->do('CREATE SCHEMA public;');
    $dbh->disconnect;
    is(system("perl ./script/initdb --init_database"), 0);
    # make sure the assets are prefetched
    ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));
}

done_testing;
