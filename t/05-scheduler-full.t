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
    $ENV{OPENQA_SCHEDULER_TIMESLOT}                      = 1000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION}            = 2;
    $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS}             = 2;
    $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL}            = 1;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}              = 2001;
    $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}                   = 8000;
    $ENV{OPENQA_SCHEDULER_CAPTURE_LOOP_AVOIDANCE}        = 38000;
    $ENV{OPENQA_SCHEDULER_RETRY_JOB_ALLOCATION_ATTEMPTS} = 3;

    $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST}      = 1;
    $ENV{OPENQA_SCHEDULER_KEEPALIVE_DEAD_WORKERS} = 0;
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
}

use strict;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd);
use OpenQA::Scheduler;
use OpenQA::Scheduler::Scheduler;
use OpenQA::Test::Database;
use Test::More;
use Net::DBus qw(:typing);
use Mojo::IOLoop::Server;
use OpenQA::Test::Utils qw(create_webapi create_websocket_server create_worker kill_service);
use Mojolicious;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path getcwd);

# This test have to be treated like fullstack.
plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};

init_db();
my $schema = OpenQA::Test::Database->new->create();

# Create webapi and websocket server services.
my $mojoport = Mojo::IOLoop::Server->generate_port();
my $wspid    = create_websocket_server($mojoport + 1);
my $webapi   = create_webapi($mojoport);

# Setup needed files for workers.
my $sharedir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'share')->make_path;

path($sharedir, 'factory', 'iso')->make_path;

symlink(abs_path("../os-autoinst/t/data/Core-7.2.iso"),
    path($sharedir, 'factory', 'iso')->child("Core-7.2.iso")->to_string)
  || die "can't symlink";

path($sharedir, 'tests')->make_path;

symlink(abs_path('../os-autoinst/t/data/tests/'), path($sharedir, 'tests')->child("tinycore"))
  || die "can't symlink";

# Instantiate our (hacked) scheduler
my $reactor = get_reactor();

subtest 'Scheduler backoff timing calculations' => sub {

    my $allocated;
    my $failures;

    my $c = $failures;
    for (0 .. 5) {
        ($allocated, $failures) = scheduler_step($reactor);
        $c++;
        my $expected_backoff = ((2**($c || 1)) - 1) * OpenQA::Scheduler::TIMESLOT() + 1000;
        $expected_backoff
          = $expected_backoff > OpenQA::Scheduler::MAX_BACKOFF ? OpenQA::Scheduler::MAX_BACKOFF : $expected_backoff;
        is get_scheduler_tick($reactor), $expected_backoff, "Tick was incremented due to growing failures($c)";
        is $failures, $c, "Expected failures: $c";
        is $allocated, 0, "Expected allocations: 0";
    }

    # Capture loop avoidence timer fired. back to default
    ($allocated, $failures) = scheduler_step($reactor);
    is $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval},
      $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} + 1000, "Scheduler clock got reset";

    $reactor->{tick} = $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};    # Reset to what we expect to be normal ticking
    ($allocated, $failures) = scheduler_step($reactor);
    is get_scheduler_tick($reactor), 2000, "Tick is of lowest backoff value";
    is $failures,  1;
    is $allocated, 0;
    #  $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) if $reactor->{timer}->{schedule_jobs};
    #undef $reactor;
};

#
subtest 'Scheduler worker job allocation' => sub {

    scheduler_step($reactor);    # let it go for 1 step without querying it in subtests - reset counters :)

    my $allocated;
    my $failures;


    # Step 1
    ($allocated, $failures) = scheduler_step($reactor);
    is get_scheduler_tick($reactor), 8000, "We expect the failure carried on by the previous tests";
    is $failures,  3;
    is $allocated, 0;

    my $k  = $schema->resultset("ApiKeys")->create({user_id => "99904"});
    my $k2 = $schema->resultset("ApiKeys")->create({user_id => "99904"});

    # GO GO GO GO GO!!! like crazy now
    #start_worker($k->key,  $k->secret,  "http://localhost:$mojoport", 1);
    my $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);
    sleep 20;


    # Step 1
    ($allocated, $failures) = scheduler_step($reactor);
    is get_scheduler_tick($reactor), 8000, "We expect the failure carried on by the previous tests";
    #  is $failures,  3;
    #  is $allocated, 2;
    sleep 20;
    # Step 2
    ($allocated, $failures) = scheduler_step($reactor);
    #  is get_scheduler_tick($reactor), 8000, "We expect the failure carried on by the previous tests";
    # is $failures,  3;
    # is $allocated, 2;

    kill_service($w1_pid);    # Simulate a failure!

    #and up again
    #  $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);



    #  kill_service($_) for ($w1_pid, $w2_pid);

};
#
#
kill_service($wspid);
kill_service($webapi);
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
    ok($delta > $low_limit && $delta < $high_limit,
        "timeout in range $low_limit->$high_limit (setted tick $tick, real tick occurred at $delta)");
}

sub scheduler_step {
    my $reactor = shift;
    my $started = $reactor->_now;
    my ($allocated, $failures);
    my $fired;
    my $current_tick = $reactor->{tick};
    $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}) if $reactor->{timer}->{schedule_jobs};
    $reactor->{timer}->{schedule_jobs} = $reactor->add_timeout(
        $current_tick,
        Net::DBus::Callback->new(
            method => sub {
                $fired = $reactor->_now;
                ($allocated, $failures) = OpenQA::Scheduler::Scheduler::schedule();
                $reactor->{tick} = $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval};
                $reactor->shutdown;
            }));
    $reactor->{running} = 1;
    $reactor->step;
    # Scheduler reallocate itself :)
    do { $reactor->remove_timeout($reactor->{timer}->{schedule_jobs}); delete $reactor->{timer}->{schedule_jobs}; }
      if $fired;
    range_ok($current_tick, $started, $fired) if $fired;
    return ($allocated, $failures);
}
sub get_scheduler_tick { shift->{tick} }

sub init_db {
    # Setup test DB
    path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string;
    ok -e path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->child("db.lock");
    ok(open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string));
    print $conf <<"EOC";
  [production]
  dsn = dbi:SQLite:dbname=$ENV{OPENQA_BASEDIR}/openqa/db/db.sqlite
  on_connect_call = use_foreign_keys
  on_connect_do = PRAGMA synchronous = OFF
  sqlite_unicode = 1
EOC
    close($conf);
    is(system("perl ./script/initdb --init_database"), 0);
    # make sure the assets are prefetched
    ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));
}


done_testing;
