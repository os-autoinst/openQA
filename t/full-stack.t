#!/usr/bin/env perl

# Copyright (C) 2016-2020 SUSE LLC
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

# possible reasons why this tests might fail if you run it locally:
#  * the web UI or any other openQA daemons are still running in the background
#  * a qemu instance is still running (maybe leftover from last failed test
#    execution)

use Test::Most;

BEGIN {
    # require the scheduler to be fixed in its actions since tests depends on timing
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 4000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 1;

    # ensure the web socket connection won't timeout
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 10 * 60;
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::Mojo;
use Test::Output 'stderr_like';
use Test::Warnings;
use autodie ':all';
use IO::Socket::INET;
use POSIX '_exit';
use OpenQA::CacheService::Client;
use Fcntl ':mode';
use DBI;
use Mojo::File 'path';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::SeleniumTest;
session->enable;
# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Test::Utils
  qw(create_websocket_server create_live_view_handler setup_share_dir),
  qw(cache_minion_worker cache_worker_service setup_fullstack_temp_dir),
  qw(stop_service);
use OpenQA::Test::FullstackUtils;

plan skip_all => 'set FULLSTACK=1 (be careful)'                                 unless $ENV{FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. "DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

my $workerpid;
my $wspid;
my $livehandlerpid;
sub turn_down_stack {
    stop_service($_) for ($workerpid, $wspid, $livehandlerpid);
}
sub stop_worker {
    is(stop_service($workerpid), $workerpid, 'WORKER is done');
    $workerpid = undef;
}

# skip if appropriate modules aren't available
unless (check_driver_modules) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# setup directories
my $tempdir  = setup_fullstack_temp_dir('full-stack.d');
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

# initialize database, start daemons
my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1, schema_name => 'public', drop_schema => 1);
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'), 'assets are prefetched');
my $mojoport = Mojo::IOLoop::Server->generate_port;
$wspid = create_websocket_server($mojoport + 1, 0, 0);
my $driver       = call_driver(sub { }, {mojoport => $mojoport});
my $connect_args = get_connect_args();
$livehandlerpid = create_live_view_handler($mojoport);

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok(-d $resultdir, "resultdir \"$resultdir\" exists");

$driver->title_is("openQA", "on main page");
is($driver->find_element('#user-action a')->get_text(), 'Login', "no one logged in");
$driver->click_element_ok('Login', 'link_text', 'Login clicked');
# we're back on the main page
$driver->title_is("openQA", "back on main page");

# click away the tour
$driver->click_element_ok('dont-notify', 'id', 'Selected to not notify about tour');
$driver->click_element_ok('confirm',     'id', 'Clicked confirm about no tour');

my $job_setup = $OpenQA::Test::FullstackUtils::JOB_SETUP;
schedule_one_job_over_api_and_verify($driver, $job_setup . ' PAUSE_AT=shutdown');

sub status_text { find_status_text($driver) }

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like(status_text, qr/State: scheduled/, 'test 1 is scheduled');
ok javascript_console_has_no_warnings_or_errors, 'no javascript warnings or errors after test 1 was scheduled';

sub start_worker {
    return fail "Unable to start worker, previous worker with PID '$workerpid' is still running" if defined $workerpid;

    $workerpid = fork();
    if ($workerpid == 0) {
        # save testing time as we do not test a webUI host being down for
        # multiple minutes
        $ENV{OPENQA_WORKER_CONNECT_RETRIES} = 1;
        exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
    else {
        ok($workerpid, "Worker started as $workerpid");
        schedule_one_job;
    }
}

sub autoinst_log { path($resultdir, '00000', sprintf("%08d", shift) . "-$job_name")->child('autoinst-log.txt') }

start_worker;
ok wait_for_job_running($driver), 'test 1 is running';

subtest 'wait until developer console becomes available' => sub {
    # open developer console
    $driver->get('/tests/1/developer/ws-console');
    wait_for_ajax(msg => 'developer console available');
    ok wait_for_developer_console_available($driver), 'developer console for test 1';
};

subtest 'pause at certain test' => sub {
    # load Selenium::Remote::WDKeys module or skip this test if not available
    unless (can_load(modules => {'Selenium::Remote::WDKeys' => undef,})) {
        plan skip_all => 'Install Selenium::Remote::WDKeys to run this test';
        return;
    }

    # wait until the shutdown test is started and hence the test execution paused
    wait_for_developer_console_like($driver, qr/(\"paused\":|\"test_execution_paused\":\".*\")/, 'paused');

    # resume the test execution again
    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');
};

$driver->get($job_page_url);
ok wait_for_result_panel($driver, qr/Result: passed/), 'test 1 is passed';
my $autoinst_log = autoinst_log(1);
ok(-s $autoinst_log,                                                         'log file generated');
ok(-s path($sharedir, 'factory', 'hdd')->make_path->child('core-hdd.qcow2'), 'image of hdd uploaded');
my $core_hdd_path = path($sharedir, 'factory', 'hdd')->child('core-hdd.qcow2');
my @core_hdd_stat = stat($core_hdd_path);
ok(@core_hdd_stat, 'can stat ' . $core_hdd_path);
is(S_IMODE($core_hdd_stat[2]), 420, 'exported image has correct permissions (420 -> 0644)');

my $post_group_res = client_output "-X POST job_groups name='New job group'";
my $group_id       = ($post_group_res =~ qr/id.+([0-9]+)/);
ok($group_id, 'regular post via client script');
client_call(qq{-X PUT jobs/1 --json --data '{"group_id":$group_id}'},
    qr/job_id.+1/, 'send JSON data via client script');
client_call('jobs/1', qr/group_id.+$group_id/, 'group has been altered correctly');

client_call('-X POST jobs/1/restart', qr|test_url.+1.+tests.+2|, 'client returned new test_url');
#]| restore syntax highlighting
$driver->refresh();
like(status_text, qr/Cloned as 2/, 'test 1 is restarted');
$driver->click_element_ok('2', 'link_text', 'clicked link to test 2');

# start a job and stop the worker; the job should be incomplete
# note: We might not be able to stop the job fast enough so there's a race condition. We could use the pause feature
#       of the developer mode to prevent that.
schedule_one_job;
ok wait_for_job_running($driver), 'job running';
stop_worker;
ok wait_for_result_panel($driver, qr/Result: incomplete/), 'test 2 crashed';
like(status_text, qr/Cloned as 3/, 'test 2 is restarted by killing worker');

my $JOB_SETUP = $OpenQA::Test::FullstackUtils::JOB_SETUP;
client_call("-X POST jobs $job_setup MACHINE=noassets HDD_1=nihilist_disk.hda");

subtest 'cancel a scheduled job' => sub {
    $driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests');
    wait_for_ajax(msg => 'wait for All Tests displayed before looking for 3');
    $driver->click_element_ok('core@coolone', 'link_text', 'clicked on 3');

    # it can happen that the test is assigned and needs to wait for the scheduler
    # to detect it as dead before it's moved back to scheduled
    ok wait_for_result_panel($driver, qr/State: scheduled/, undef, 0.2), 'Test 3 is scheduled';

    my @cancel_button = $driver->find_elements('cancel_running', 'id');
    $cancel_button[0]->click();
};

$driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests to go to test 4');
wait_for_ajax(msg => 'wait for All Tests displayed before looking for 3');
$driver->click_element_ok('core@noassets', 'link_text', 'clicked on 4');
$job_name = 'tinycore-1-flavor-i386-Build1-core@noassets';
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
like(status_text, qr/State: scheduled/, 'test 4 is scheduled');

ok javascript_console_has_no_warnings_or_errors, 'no javascript warnings or errors after test 4 was scheduled';
start_worker;

ok wait_for_result_panel($driver, qr/Result: incomplete/), 'Test 4 crashed as expected';

$autoinst_log = autoinst_log(4);
# give it some time to be created
for (1 .. 50) {
    last if -s $autoinst_log;
    sleep .1;
}

ok -s $autoinst_log, 'Test 4 autoinst-log.txt file created';
my $log_content = $autoinst_log->slurp;
like($log_content, qr/Result: setup failure/, 'Test 4 result correct: setup failure');
like((split(/\n/, $log_content))[0],  qr/\+\+\+ setup notes \+\+\+/,  'Test 4 correct autoinst setup notes');
like((split(/\n/, $log_content))[-1], qr/Uploading autoinst-log.txt/, 'Test 4: upload of autoinst-log.txt logged');
stop_worker;    # Ensure that the worker can be killed with TERM signal

my $cache_location = path($ENV{OPENQA_BASEDIR}, 'cache')->make_path;
ok(-e $cache_location, "Setting up Cache directory");

path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt(<<EOC);
[global]
CACHEDIRECTORY = $cache_location
CACHELIMIT = 50

[1]
WORKER_CLASS = qemu_i386,qemu_x86_64

[http://localhost:$mojoport]
TESTPOOLSERVER = $sharedir/tests
EOC
ok(-e path($ENV{OPENQA_CONFIG})->child("workers.ini"), 'Config file created');

# For now let's repeat the cache tests before extracting to separate test
subtest 'Cache tests' => sub {
    my $cache_service        = cache_worker_service;
    my $worker_cache_service = cache_minion_worker;

    my $db_file = $cache_location->child('cache.sqlite');
    ok(!-e $db_file, "cache.sqlite is not present");

    my $filename = $cache_location->child("test.file")->spurt('Hello World');
    path($cache_location, "test_directory")->make_path;

    $worker_cache_service->restart->restart;
    $cache_service->restart->restart;

    my $cache_client                = OpenQA::CacheService::Client->new;
    my $supposed_cache_service_host = $cache_client->host;
    my $cache_service_timeout       = 60;
    for (1 .. $cache_service_timeout) {
        last if $cache_client->info->available;
        note "Waiting for cache service to be available under $supposed_cache_service_host";
        sleep 1;
    }
    ok $cache_client->info->available, 'cache service is available';
    my $cache_worker_timeout = 60;
    for (1 .. $cache_worker_timeout) {
        last if $cache_client->info->available_workers;
        note "Waiting for cache service worker to be available";
        sleep 1;
    }
    ok $cache_client->info->available_workers, 'cache service worker is available';
    $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
    client_call("-X POST jobs $job_setup PUBLISH_HDD_1=");
    $driver->get('/tests/5');
    like(status_text, qr/State: scheduled/, 'test 5 is scheduled')
      or die;
    start_worker;
    ok wait_for_job_running($driver, 1), 'job running';
    ok(-e $db_file,                                 "cache.sqlite file created");
    ok(!-d path($cache_location, "test_directory"), "Directory within cache, not present after deploy");
    ok(!-e $cache_location->child("test.file"),     "File within cache, not present after deploy");

    my $link = path($ENV{OPENQA_BASEDIR}, 'openqa', 'pool', '1')->child('Core-7.2.iso');
    sleep 5 and note "Waiting for cache service to finish the download" until -e $link;

    my $cached = $cache_location->child('localhost', 'Core-7.2.iso');
    is $cached->stat->ino, $link->stat->ino, 'iso is hardlinked to cache';

    ok wait_for_result_panel($driver, qr/Result: passed/), 'test 5 is passed';
    stop_worker;
    $autoinst_log = autoinst_log(5);
    ok -s $autoinst_log, 'Test 5 autoinst-log.txt file created';
    my $log_content = $autoinst_log->slurp;
    like($log_content, qr/Downloading Core-7.2.iso/, 'Test 5, downloaded the right iso.');
    like($log_content, qr/11116544/,                 'Test 5 Core-7.2.iso size is correct.');
    like($log_content, qr/Result: done/,             'Test 5 result done');
    like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 5 correct autoinst setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i,
        'Test 5 correct autoinst uploading autoinst');
    my $dbh
      = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1});
    my $sql    = "SELECT * from assets order by last_use asc";
    my $sth    = $dbh->prepare($sql);
    my $result = $dbh->selectrow_hashref($sql);
    # We know it's going to be this host because it's what was defined in
    # the worker ini
    like($result->{filename}, qr/Core-7/, "Core-7.2.iso is the first element");

    # create assets at same time and in the following seconds after the above
    my $time = $result->{last_use};
    for (1 .. 5) {
        $filename = $cache_location->child("$_.qcow2");
        path($filename)->spurt($filename);
        # so that last_use is not the same for every item
        $time++;
        $sql = "INSERT INTO assets (filename,etag,last_use) VALUES ( ?, 'Not valid', $time);";
        $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $filename);
        $sth->execute();
    }

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);
    like($result->{filename}, qr/5.qcow2$/, "file #5 is the newest element");

    # Delete image #5 so that it gets cleaned up when the worker is initialized.
    $sql = "delete from assets where filename = ? ";
    $dbh->prepare($sql)->execute($result->{filename});

    #simple limit testing.
    client_call('-X POST jobs/5/restart', qr|test_url.+5.+tests.+6|, 'client returned new test_url');

    $driver->get('/tests/6');
    like(status_text, qr/State: scheduled/, 'test 6 is scheduled');
    start_worker;
    ok wait_for_result_panel($driver, qr/Result: passed/), 'test 6 is passed';
    stop_worker;
    $autoinst_log = autoinst_log(6);
    ok -s $autoinst_log, 'Test 6 autoinst-log.txt file created';

    ok(!-e $result->{filename}, "asset 5.qcow2 removed during cache init");

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);

    like($result->{filename}, qr/Core-7/, "Core-7.2.iso the most recent asset again ");

    #simple limit testing.
    client_call('-X POST jobs/6/restart', qr|test_url.+6.+tests.+7|, 'client returned new test_url');
    $driver->get('/tests/7');
    like(status_text, qr/State: scheduled/, 'test 7 is scheduled');
    start_worker;
    ok wait_for_result_panel($driver, qr/Result: passed/), 'test 7 is passed';
    $autoinst_log = autoinst_log(7);
    ok -s $autoinst_log, 'Test 7 autoinst-log.txt file created';
    $log_content = $autoinst_log->slurp;
    like($log_content, qr/\+\+\+\ worker notes \+\+\+/, 'Test 7 has worker notes');
    like((split(/\n/, $log_content))[0],  qr/\+\+\+ setup notes \+\+\+/,   'Test 7 has setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'Test 7 uploaded autoinst-log (as last)');
    client_call("-X POST jobs $job_setup HDD_1=non-existent.qcow2");
    schedule_one_job;
    $driver->get('/tests/8');
    ok wait_for_result_panel($driver, qr/Result: incomplete/), 'test 8 is incomplete';

    subtest 'log shown within details tab (without page reload)' => sub {
        $driver->find_element_by_link_text('Details')->click();
        wait_for_ajax(msg => 'autoinst log embedded within "Details" tab');
        ok(my $log = $driver->find_element('.embedded-logfile'), 'element for embedded logfile present');
        wait_for_ajax(msg => 'log contents loaded');
        like($log->get_text(), qr/Result: setup failure/, 'log contents present');
    };

    $autoinst_log = autoinst_log(8);
    ok -s $autoinst_log, 'Test 8 autoinst-log.txt file created';
    $log_content = $autoinst_log->slurp;
    like($log_content, qr/\+\+\+\ worker notes \+\+\+/, 'Test 8 has worker notes');
    like((split(/\n/, $log_content))[0],  qr/\+\+\+ setup notes \+\+\+/,   'Test 8 has setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'Test 8 uploaded autoinst-log (as last)');
    like($log_content, qr/Failed to download.*non-existent.qcow2/, 'Test 8 failure message found in log');
    like($log_content, qr/Result: setup failure/,                  'Test 8 state correct: setup failure');
    stop_worker;
};

done_testing;

END {
    kill_driver;
    turn_down_stack;
    session->clean;
    $? = 0;
    $tempdir->list_tree->grep(qr/\.txt$/)->each(sub { print "$_:\n" . $_->slurp }) if defined $tempdir;
}
