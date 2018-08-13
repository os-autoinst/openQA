#!/usr/bin/env perl -w

# Copyright (C) 2014-2017 SUSE LLC
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

use Mojo::File qw(path tempdir);
BEGIN {
    unshift @INC, 'lib';
    #  push @INC, '.';
    use FindBin;
    $ENV{OPENQA_BASEDIR} = path(tempdir, 't', 'scheduler');
    $ENV{OPENQA_CONFIG} = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_TIMESLOT}               = 1000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION}     = 10;
    $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS}      = 2;
    $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL}     = 1;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}       = 2000;
    $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}            = 4000;
    $ENV{OPENQA_SCHEDULER_CAPTURE_LOOP_AVOIDANCE} = 38000;
    $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST}      = 0;
    $ENV{FULLSTACK}                               = 1 if $ENV{SCHEDULER_FULLSTACK};
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
}

use strict;
use lib "$FindBin::Bin/lib";
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use Data::Dump qw(pp dd);
use OpenQA::Scheduler;
use OpenQA::Scheduler::Scheduler;
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Net::DBus qw(:typing);
use Mojo::IOLoop::Server;
use Mojo::File 'tempfile';
use OpenQA::Test::Utils qw(
  create_webapi wait_for_worker setup_share_dir
  create_resourceallocator start_resourceallocator create_websocket_server create_worker
  kill_service unstable_worker client_output unresponsive_worker
);
use Mojolicious;
use File::Path qw(make_path remove_tree);
use DateTime;
# This test have to be treated like fullstack.
plan skip_all => "set SCHEDULER_FULLSTACK=1 (be careful)" unless $ENV{SCHEDULER_FULLSTACK};

init_db();
my $schema = OpenQA::Test::Database->new->create(skip_schema => 1);

# Create webapi and websocket server services.
my $mojoport             = Mojo::IOLoop::Server->generate_port();
my $webapi               = create_webapi($mojoport);
my $resourceallocatorpid = start_resourceallocator;
my $wspid                = create_websocket_server($mojoport + 1, 0, 1, 1);

my $reactor = get_reactor();
# Setup needed files for workers.

my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir;

my $k = $schema->resultset("ApiKeys")->create({user_id => "99903"});

subtest 'Scheduler backoff timing calculations' => sub {
    dead_workers($schema);

    my $allocated;
    my $failures;
    my $no_actions;
    my $c;

    scheduler_step($reactor) for (0 .. 11);
    trigger_capture_event_loop($reactor);

    for (0 .. 8) {
        $c++;
        ($allocated, $failures, $no_actions) = scheduler_step($reactor);
        is $failures, $c, "Expected failures: $c";
        is @$allocated, 0, "Expected allocations: 0";
        is $no_actions, $c, "No actions performed will match failures - since we have no free workers";
    }

};
subtest 'Scheduler worker job allocation' => sub {

    my $allocated;
    my $failures;
    my $no_actions;


    trigger_capture_event_loop($reactor);

    #
    # Step 1
    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   1;
    is $no_actions, $failures;
    is @$allocated, 0;

    # GO GO GO GO GO!!! like crazy now
    my $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);
    my $w2_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 2);
    sleep 5;

    # Step 1
    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures, 0;
    is @$allocated, 2;

    my $job_id1 = $allocated->[0]->{job};
    my $job_id2 = $allocated->[1]->{job};
    my $wr_id1  = $allocated->[0]->{worker};
    my $wr_id2  = $allocated->[1]->{worker};
    ok $wr_id1 != $wr_id2,   "Jobs dispatched to different workers";
    ok $job_id1 != $job_id2, "Jobs dispatched to different workers";


    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   0;
    is $no_actions, 1;
    is @$allocated, 0;

    dead_workers($schema);

    kill_service($_, 1) for ($w1_pid, $w2_pid);
};

subtest 'Simulation of unstable workers' => sub {
    my $allocated;
    my $failures;
    my $no_actions;


    my @latest = $schema->resultset("Jobs")->latest_jobs;

    shift(@latest)->auto_duplicate();

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is $failures,   1;
    is $no_actions, 2;

# Now let's simulate unstable workers :)
# In this way the worker will associate, will be registered but won't perform any operation - will just send statuses that is free.
    my $unstable_w_pid = unresponsive_worker($k->key, $k->secret, "http://localhost:$mojoport", 3);

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is @$allocated, 1;
    is @{$allocated}[0]->{job},    99982;
    is @{$allocated}[0]->{worker}, 5;

    for (0 .. 100) {
        last if $schema->resultset("Jobs")->find(99982)->state eq OpenQA::Jobs::Constants::SCHEDULED;
        sleep 2;
    }

    is $schema->resultset("Jobs")->find(99982)->state, OpenQA::Jobs::Constants::SCHEDULED,
      "If worker declares to be free - reschedule assigned job to that worker";
    kill_service($unstable_w_pid, 1);
    sleep 5;

    scheduler_step($reactor);
    reset_tick($reactor);
    dead_workers($schema);

    # Same job, since was put in scheduled state again.
    $unstable_w_pid = unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", 3, 8);
    wait_for_worker($schema, 5);

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   0;
    is $no_actions, 0;
    is @$allocated, 1;
    is @{$allocated}[0]->{job},    99982;
    is @{$allocated}[0]->{worker}, 5;

    kill_service($unstable_w_pid, 1);
    ok $schema->resultset("Jobs")->find(99982)->state eq OpenQA::Jobs::Constants::ASSIGNED;

    $unstable_w_pid = unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", 3, 8);

    for (0 .. 100) {
        last if $schema->resultset("Jobs")->find(99982)->state eq OpenQA::Jobs::Constants::DONE;
        sleep 2;
    }

    is $schema->resultset("Jobs")->find(99982)->state, OpenQA::Jobs::Constants::DONE,
      "Job is done - worker re-connected";
    is $schema->resultset("Jobs")->find(99982)->result, OpenQA::Jobs::Constants::INCOMPLETE,
      "Job result is incomplete - worker re-connected";

    dead_workers($schema);
    kill_service($unstable_w_pid, 1);
};

subtest 'Simulation of heavy unstable load' => sub {
    my $allocated;
    my $failures;
    my $no_actions;
    my @workers;
    dead_workers($schema);
    my @duplicated;

    push(@duplicated, $_->auto_duplicate()) for $schema->resultset("Jobs")->latest_jobs;

    push(@workers, unresponsive_worker($k->key, $k->secret, "http://localhost:$mojoport", $_)) for (1 .. 50);
    sleep 5;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is @$allocated, 10, "Allocated maximum number of jobs that could have been allocated";
    is $failures, 2, "Failure count should be to 2, since we took too much time to schedule";
    is get_scheduler_tick($reactor), 2**$failures * $ENV{OPENQA_SCHEDULER_TIMESLOT}, "Tick is at the expected value";
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
    my $i = 5;
    wait_for_worker($schema, ++$i) for 0 .. 12;
    trigger_capture_event_loop($reactor);

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is @$allocated, 0, "All failed allocation on second step - workers were killed";
    ok $failures >= 8, "Failure count($failures) should be >=8, since we took too much time to schedule";
    is get_scheduler_tick($reactor), $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}, "Tick is at the expected value";

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
    my $log_file = tempfile;
    local $ENV{OPENQA_LOGFILE};
    local $ENV{MOJO_LOG_LEVEL};
    my $unstable_ws_pid = create_websocket_server($mojoport + 1, 1, 0, 1);
    my $w2_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 2, $log_file);
    my $re = qr/\[.*?\]\sConnection turned off from .*?\- (.*?)\s\:(.*?) dead/;

    my $attempts = 800;
    do {
        sleep 1;
        $attempts--;
    } until ((() = $log_file->slurp() =~ m/$re/g) >= 1 || $attempts <= 0);
    kill_service($_) for ($unstable_ws_pid, $w2_pid);
    dead_workers($schema);
    my @matches = $log_file->slurp() =~ m/$re/g;
    is $matches[0], "1008", "Connection was turned off by ws server correctly - code error is 1008";
    like $matches[1], qr/Connection terminated from WebSocket server/,
      "Connection was turned off by ws server correctly";
};

# This test destroys almost everything.
subtest 'Simulation of heavy failures' => sub {
    my $allocated;
    my $failures;
    my $no_actions;
    my @workers;

    kill_service($wspid);

    dead_workers($schema);

    trigger_capture_event_loop($reactor);
    scheduler_step($reactor);

    # Destroy db to achieve maximum failures - simulate when we can't reach db to update states.
    my $dbh = DBI->connect($ENV{TEST_PG});
    $dbh->do('DROP SCHEMA public CASCADE;');
    $dbh->do('CREATE SCHEMA public;');
    $dbh->disconnect;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is @$allocated, 0, "Everything is failing as expected - 0 allocations";
    is $failures , $no_actions, "Failure count should be 2";
    is $no_actions, 2, '2 Actions were performed';
    is get_scheduler_tick($reactor), $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}, "Tick is at the expected value";

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is @$allocated, 0, "Everything is failing as expected - 0 allocations";
    is $failures , $no_actions, "Failure count should be 3";
    is $no_actions, 3, '3 Actions were performed';
    is get_scheduler_tick($reactor), $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}, "Tick is at the expected value";


    kill_service($_, 1) for @workers;
};

kill_service($_) for ($wspid, $webapi, $resourceallocatorpid);

sub dead_workers {
    my $schema = shift;
    $_->update({t_updated => DateTime->from_epoch(epoch => time - 10200)}) for $schema->resultset("Workers")->all();
}

sub reset_tick {
    my $reactor = shift;

    eval { $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) } if exists $reactor->{timer}->{schedule_jobs};
    delete $reactor->{timer}->{schedule_jobs};
    $reactor->{tick} = $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};    # Reset to what we expect to be normal ticking
    return $reactor;
}

sub remove_timers {
    my $reactor = shift;

    $reactor->{timeouts} = [undef];                                # This is Net::DBus default...
    delete $reactor->{timer}->{no_actions_reset};
    delete $reactor->{timer}->{capture_loop_avoidance};
}

sub trigger_capture_event_loop {
    my $reactor = shift;

    # Capture loop avoidance timer fired. back to default
    $reactor->{running} = 1;
    $reactor->step;
    $reactor->{running} = 0;

    is $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval},
      $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} + 1000, "Scheduler clock got reset";    #scheduler_step($reactor);

    reset_tick($reactor);
    remove_timers($reactor);

    return $reactor;
}

sub get_reactor {
    # Instantiate our (hacked) scheduler
    OpenQA::Scheduler->new();
    my $reactor = Net::DBus::Reactor->main;
    OpenQA::Scheduler::Scheduler::reactor($reactor);
    $reactor->{tick} //= $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};
    return $reactor;
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

sub scheduler_step {
    use Data::Dumper;
    my $reactor = shift;
    my $started = $reactor->_now;
    my ($allocated, $failures, $no_actions, $rescheduled);
    my $fired;

    my $current_tick = $reactor->{tick} // $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};
    eval { $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) } if exists $reactor->{timer}->{schedule_jobs};

    my $tid = $reactor->add_timeout(
        $current_tick,
        Net::DBus::Callback->new(
            method => sub {
                $fired = $reactor->_now;
                ($allocated, $failures, $no_actions, $rescheduled) = OpenQA::Scheduler::Scheduler::schedule();
                print STDERR Dumper($allocated) . "\n";

                $reactor->{tick} = $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval};
                eval { $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) }
                  if exists $reactor->{timer}->{schedule_jobs};    # Scheduler reallocate itself :)
                                                                   #  $reactor->shutdown;

            }));
    $reactor->{timer}->{schedule_jobs} = $tid;
    diag 'Running scheduler step';
    $reactor->{running} = 1;
    $reactor->step;
    $reactor->{running} = 0;
    $reactor->{timer}->{schedule_jobs} = $tid;
    $failures   = 0 if !defined $failures;
    $no_actions = 0 if !defined $no_actions;
    $reactor->shutdown;

    eval { $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) }
      if exists $reactor->{timer}->{schedule_jobs};    # Scheduler reallocate itself :)

    range_ok($current_tick, $started, $fired) if $fired;

    my $backoff = ((2**((($failures ? $failures : 0) + ($no_actions ? $no_actions : 0)) || 2)) - 1)
      * $ENV{OPENQA_SCHEDULER_TIMESLOT};
    $backoff = $backoff > $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} ? $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} : $backoff + 1000;
    is get_scheduler_tick($reactor), $backoff,
      "Tick is at the expected value ($backoff) (failures $failures) (no_actions $no_actions)"
      if $rescheduled;

    return ($allocated, $failures, $no_actions);
}
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
