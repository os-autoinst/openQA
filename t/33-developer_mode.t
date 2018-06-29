#! /usr/bin/perl

# Copyright (C) 2018 SUSE LLC
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

# possible reasons why this tests might fail if you run it locally:
#  * the web UI or any other openQA daemons are still running in the background
#  * a qemu instance is still running (maybe leftover from last failed test
#    execution)

BEGIN {
    unshift @INC, 'lib';
    use FindBin;
    use Mojo::File qw(path tempdir);
    $ENV{OPENQA_BASEDIR} = path(tempdir, 't', 'full-stack.d');
    $ENV{OPENQA_CONFIG} = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 4000;
    $ENV{OPENQA_SCHEDULER_TIMESLOT}           = $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 1;
    $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS}  = 1;
    $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL} = 1;
    $ENV{OPENQA_SCHEDULER_BUSY_BACKOFF}       = 1;
    $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}        = 8000;
    $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST}  = 0;
    # ensure the web socket connection won't timeout
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 10 * 60;
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
    # DO NOT SET OPENQA_IPC_TEST HERE
}

# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;

use Mojo::Base -strict;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Mojo;
use Test::Output 'stderr_like';
use Data::Dumper;
use IO::Socket::INET;
use POSIX '_exit';
use Fcntl ':mode';
use DBI;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Test::Utils
  qw(create_websocket_server create_live_view_handler create_resourceallocator start_resourceallocator setup_share_dir);
use OpenQA::Test::FullstackUtils;

plan skip_all => 'set DEVELOPER_FULLSTACK=1 (be careful)' unless $ENV{DEVELOPER_FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

# load Selenium::Remote::WDKeys module or skip this test if not available
unless (can_load(modules => {'Selenium::Remote::WDKeys' => undef,})) {
    plan skip_all => 'Install Selenium::Remote::WDKeys to run this test';
    exit(0);
}

my $workerpid;
my $wspid;
my $livehandlerpid;
my $schedulerpid;
my $resourceallocatorpid;
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

sub turn_down_stack {
    for my $pid ($workerpid, $wspid, $livehandlerpid, $schedulerpid, $resourceallocatorpid) {
        next unless $pid;
        kill TERM => $pid;
        waitpid($pid, 0);
    }
}

sub kill_worker {
    kill TERM => $workerpid;
    is(waitpid($workerpid, 0), $workerpid, 'WORKER is done');
    $workerpid = undef;
}

use OpenQA::SeleniumTest;

# skip if appropriate modules aren't available
unless (check_driver_modules) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

OpenQA::Test::FullstackUtils::setup_database();

# make sure the assets are prefetched
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));

# start scheduler
$schedulerpid = fork();
if ($schedulerpid == 0) {
    use OpenQA::Scheduler;
    OpenQA::Scheduler::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}

# start resource allocator
$resourceallocatorpid = start_resourceallocator;

# start Selenium test driver without fixtures usual fixtures but an additional admin user
my $driver = call_driver(
    sub {
        my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1, skip_schema => 1);
        my $users = $schema->resultset('Users');

        # create the admins 'Demo' and 'otherdeveloper'
        for my $user_name (qw(Demo otherdeveloper)) {
            $users->create(
                {
                    username        => $user_name,
                    nickname        => $user_name,
                    is_operator     => 1,
                    is_admin        => 1,
                    feature_version => 0,
                });
        }
    });
my $mojoport     = OpenQA::SeleniumTest::get_mojoport;
my $connect_args = OpenQA::Test::FullstackUtils::get_connect_args();

# make resultdir
my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok(-d $resultdir, "resultdir \"$resultdir\" exists");

# login
$driver->title_is('openQA', 'on main page');
is($driver->find_element('#user-action a')->get_text(), 'Login', 'no one initially logged-in');
$driver->click_element_ok('Login', 'link_text');
$driver->title_is('openQA', 'back on main page');

# setup websocket server
my $wsport = $mojoport + 1;
$wspid = create_websocket_server($wsport, 0, 0, 0);

# start live view handler
$livehandlerpid = create_live_view_handler($mojoport);

my $JOB_SETUP
  = 'ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
  . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 INTEGRATION_TESTS=1'
  . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2';

# schedule job
OpenQA::Test::FullstackUtils::client_call("jobs post $JOB_SETUP");

# verify it's displayed scheduled
$driver->click_element_ok('All Tests', 'link_text');
$driver->title_is('openQA: Test results', 'tests followed');
like($driver->get_page_source(), qr/\Q<h2>1 scheduled jobs<\/h2>\E/, '1 job scheduled');
wait_for_ajax;

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');
javascript_console_has_no_warnings_or_errors;

sub start_worker {
    $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
}

start_worker;
OpenQA::Test::FullstackUtils::wait_for_job_running($driver, 'fail on incomplete');

sub wait_for_session_info {
    my ($info_regex, $diag_info) = @_;

    # give the session info 10 seconds to appear
    my $developer_session_info = $driver->find_element('#developer-session-info')->get_text();
    my $seconds_waited         = 0;
    while (!$developer_session_info) {
        if ($seconds_waited > 10) {
            fail('no session info after 10 seconds, expected ' . $diag_info);
            return;
        }

        sleep 1;
        $developer_session_info = $driver->find_element('#developer-session-info')->get_text();
        $seconds_waited += 1;
    }

    like($developer_session_info, $info_regex, $diag_info);
}

my $developer_console_url = '/tests/1/developer/ws-console?proxy=1';
subtest 'wait until developer console becomes available' => sub {
    $driver->get($developer_console_url);
    OpenQA::Test::FullstackUtils::wait_for_developer_console_available($driver);
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/(connected to os-autoinst command server|reusing previous connection to os-autuinst command server)/,
        'proxy says it is connected to os-autoinst cmd srv'
    );
};

subtest 'pause at certain test' => sub {
    # send command to pause at shutdown (hopefully the test wasn't so fast it is already in shutdown)
    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"set_pause_at_test","name":"shutdown"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/\"set_pause_at_test\":\"shutdown\"/,
        'response to set_pause_at_test'
    );

    # wait until the shutdown test is started and hence the test execution paused
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message($driver,
        qr/(\"paused\":|\"test_execution_paused\":1)/, 'paused');
};

subtest 'developer session visible in live view' => sub {
    $driver->get($job_page_url);
    $driver->find_element_by_link_text('Live View')->click();

    subtest 'initial state of UI controls' => sub {
        wait_for_session_info(qr/owned by Demo/, 'user displayed');
        element_visible('#developer-instructions',       qr/connect to .* at port 91/);
        element_visible('#developer-panel .card-header', qr/paused/);
        element_hidden('#developer-panel .card-body');
    };

    subtest 'expand developer panel' => sub {
        $driver->find_element('#developer-panel .card-header')->click();
        element_visible(
            '#developer-panel .card-body',
            [
                qr/Change the test behaviour with the controls below\./,
                qr/Resume test execution/,
                qr/Cancel job/, qr/Resume/,
            ],
            [qr/Confirm to control this test/,],
        );

        my @module_options = $driver->find_elements('#developer-pause-at-module option');
        my @module_names = map { $_->get_text() } @module_options;
        is_deeply(\@module_names, ['Do not pause', 'boot', 'shutdown',], 'module');
    };
};

subtest 'status-only route accessible for other users' => sub {
    $driver->get('/logout');
    $driver->get('/login?user=otherdeveloper');
    is($driver->find_element('#user-action a')->get_text(), 'Logged in as otherdeveloper', 'otherdeveloper logged-in');

    $driver->get($job_page_url);
    $driver->find_element_by_link_text('Live View')->click();

    subtest 'initial state of UI controls' => sub {
        wait_for_session_info(qr/owned by Demo/, 'user displayed');
        element_visible('#developer-instructions',       qr/connect to .* at port 91/);
        element_visible('#developer-panel .card-header', qr/paused/);
        element_hidden('#developer-panel .card-body');
    };

    subtest 'expand developer panel' => sub {
        $driver->find_element('#developer-panel .card-header')->click();
        element_visible(
            '#developer-panel .card-body',
            [qr/Another user has already locked this job./],
            [
                qr/below and confirm to apply/,
                qr/with the controls below\./,
                qr/Pause at module/,
                qr/boot/,
                qr/shutdown/,
                qr/Confirm to control this test/,
                qr/Cancel job/,
                qr/Resume/,
            ],
        );
    };
};

subtest 'developer session locked for other developers' => sub {
    $driver->get($developer_console_url);

    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/unable to create \(further\) development session/,
        'no further session'
    );
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message($driver, qr/Connection closed/,
        'closed');
};

my $first_tab  = $driver->get_current_window_handle();
my $second_tab = open_new_tab('/login?user=Demo');

subtest 'connect with 2 clients at the same time (use case: developer opens 2nd tab)' => sub {
    $driver->switch_to_window($second_tab);

    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/Connection opened/,
        'connection opened'
    );
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/reusing previous connection to os-autoinst/,
        'connection reused'
    );
};


subtest 'resume test execution' => sub {
    # login as demo again
    $driver->switch_to_window($first_tab);
    $driver->get('/logout');
    $driver->get('/login?user=Demo');

    # go back to the live view
    $driver->get($job_page_url);
    $driver->find_element_by_link_text('Live View')->click();
    wait_for_session_info(qr/owned by Demo.*2 tabs open/,
        '2 browser tabs open (live view and tab from previous subtest)');

    # open developer console
    $driver->get($developer_console_url);
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/Connection opened/,
        'connection opened'
    );

    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message($driver,
        qr/\"resume_test_execution\":/, 'resume');

    # check whether info has also been distributed to 2nd tab
    $driver->switch_to_window($second_tab);
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/\"resume_test_execution\":/,
        'resume (2nd tab)'
    );
};


subtest 'quit session' => sub {
    $driver->switch_to_window($first_tab);

    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"quit_development_session"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message($driver, qr/Connection closed/,
        'closed');

    # check whether 2nd client has been kicked out as well
    $driver->switch_to_window($second_tab);
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/Connection closed/,
        'closed (2nd tab)'
    );
};

subtest 'test cancelled by quitting the session' => sub {
    $driver->switch_to_window($first_tab);
    $driver->get($job_page_url);
    OpenQA::Test::FullstackUtils::wait_for_result_panel(
        $driver,
        qr/Result: user_cancelled/,
        'test 1 has been cancelled'
    );
    ok(-s path($resultdir, '00000', "00000001-$job_name")->make_path->child('autoinst-log.txt'), 'log file generated');
};

kill_driver;
turn_down_stack;
done_testing;

# in case it dies
END {
    kill_driver;
    turn_down_stack;
    $? = 0;
}
