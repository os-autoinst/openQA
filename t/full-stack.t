#!/usr/bin/env perl

# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# possible reasons why this tests might fail if you run it locally:
#  * the web UI or any other openQA daemons are still running in the background
#  * a qemu instance is still running (maybe leftover from last failed test
#    execution)

use Test::Most;

BEGIN {
    # require the scheduler to be fixed in its actions since tests depends on timing
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} = 4000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 1;

    # ensure the web socket connection won't timeout
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 10 * 60;
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use autodie ':all';
use IO::Socket::INET;
use POSIX '_exit';
use OpenQA::CacheService::Client;
use Fcntl ':mode';
use DBI;
use Time::HiRes 'sleep';
use Mojo::File 'path';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Jobs::Constants qw(INCOMPLETE);
use OpenQA::Utils qw(service_port);
use OpenQA::SeleniumTest;
session->enable;

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Test::Utils
  qw(create_websocket_server create_live_view_handler setup_share_dir),
  qw(cache_minion_worker cache_worker_service mock_service_ports setup_fullstack_temp_dir),
  qw(start_worker stop_service wait_for_or_bail_out);
use OpenQA::Test::TimeLimit '200';
use OpenQA::Test::FullstackUtils;

plan skip_all => 'set FULLSTACK=1 (be careful)' unless $ENV{FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. "DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

my $worker;
my $ws;
my $livehandler;
sub turn_down_stack {
    stop_service($_) for ($worker, $ws, $livehandler);
}
sub stop_worker { stop_service $worker }

driver_missing unless check_driver_modules;

# setup directories
my $tempdir = setup_fullstack_temp_dir('full-stack.d');
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

# initialize database, start daemons
my $schema = OpenQA::Test::Database->new->create(schema_name => 'public', drop_schema => 1);
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'), 'assets are prefetched');
mock_service_ports;
my $mojoport = service_port 'websocket';
$ws = create_websocket_server($mojoport, 0, 0);
my $driver = call_driver({mojoport => service_port 'webui'});
$livehandler = create_live_view_handler;

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok(-d $resultdir, "resultdir \"$resultdir\" exists");

$driver->title_is('openQA', 'on main page');
is($driver->find_element('#user-action a')->get_text(), 'Login', 'no one logged in');
$driver->click_element_ok('Login', 'link_text', 'Login clicked');
# we're back on the main page
$driver->title_is('openQA', 'back on main page');

# click away the tour
$driver->click_element_ok('dont-notify', 'id', 'disable tour permanently');
$driver->click_element_ok('tour-end', 'id', 'confirm dismissing tour');

schedule_one_job_over_api_and_verify($driver, OpenQA::Test::FullstackUtils::job_setup(PAUSE_AT => 'shutdown'));

sub status_text { find_status_text($driver) }

# add a function to verify the test setup before trying to run a job
my $setup_timeout = OpenQA::Test::TimeLimit::scale_timeout($ENV{OPENQA_FULLSTACK_SETUP_TIMEOUT} // 2);
sub check_scheduled_job_and_wait_for_free_worker ($worker_class) {
    # check whether the job we expect to be scheduled is actually scheduled
    # note: After all this is a test so it might uncover problems and then it is useful to have further
    #       information to know what's wrong.
    my @scheduled_jobs = values %{OpenQA::Scheduler::Model::Jobs->singleton->determine_scheduled_jobs};
    my $has_relevant_job = 0;
    for my $job (@scheduled_jobs) {
        next unless grep { $_ eq $worker_class } @{$job->{worker_classes}};    # uncoverable statement
        $has_relevant_job = 1;
        last;
    }
    ok $has_relevant_job, "job with worker class $worker_class scheduled"
      or diag explain 'scheduled jobs: ', \@scheduled_jobs;

    # wait until there's not only a free worker but also one with matching worker properties
    # note: Populating the database is not done atomically so a worker might already show up but relevant
    #       properties (most importantly WEBSOCKET_API_VERSION and WORKER_CLASS) have not been populated yet.
    my ($elapsed, $free_workers) = (0, []);
    for (; $elapsed <= $setup_timeout; $elapsed += sleep 0.1) {
        for my $worker (@{$free_workers = OpenQA::Scheduler::Model::Jobs::determine_free_workers}) {
            return pass "at least one free worker with class $worker_class registered"
              if $worker->check_class($worker_class);
        }
    }
    # uncoverable statement
    fail "no worker with class $worker_class showed up after $elapsed seconds";
    # uncoverable statement count:1
    # uncoverable statement count:2
    diag explain 'free workers: ', [map { $_->info } @$free_workers];
}

sub show_job_info {
    # uncoverable subroutine
    my ($job_id) = @_;    # uncoverable statement
    my $job = $schema->resultset('Jobs')->find($job_id);    # uncoverable statement
    diag explain 'job info: ', $job ? $job->to_hash : undef;    # uncoverable statement
}

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like(status_text, qr/State: scheduled/, 'test 1 is scheduled');
ok javascript_console_has_no_warnings_or_errors, 'no javascript warnings or errors after test 1 was scheduled';

sub assign_jobs ($worker_class = undef) {
    check_scheduled_job_and_wait_for_free_worker $worker_class // 'qemu_i386';
    OpenQA::Scheduler::Model::Jobs->singleton->schedule;
}
sub start_worker_and_assign_jobs ($worker_class = undef) {
    $worker = start_worker get_connect_args;
    ok $worker, "Worker started as $worker";
    assign_jobs $worker_class;
}

sub autoinst_log ($job_id) { path($resultdir, '00000', sprintf("%08d-$job_name", $job_id))->child('autoinst-log.txt') }
# uncoverable statement count:1
# uncoverable statement count:2
# uncoverable statement count:3
# uncoverable statement count:4
sub bail_with_log ($job_id, $message) {
    # uncoverable subroutine
    # uncoverable statement
    my $log_file = autoinst_log($job_id);
    # uncoverable statement count:1
    # uncoverable statement count:2
    my $log = eval { $log_file->slurp };
    diag $@ ? "unable to read $log_file: $@" : "$log_file:\n$log";    # uncoverable statement
    BAIL_OUT $message;    # uncoverable statement
}

start_worker_and_assign_jobs;
ok wait_for_job_running($driver, 1), 'test 1 is running' or bail_with_log 1, 'unable to run test 1';

subtest 'wait until developer console becomes available' => sub {
    # open developer console
    $driver->get('/tests/1/developer/ws-console');
    wait_for_developer_console_available($driver);
};

subtest 'pause at certain test' => sub {
    # load Selenium::Remote::WDKeys module or skip this test if not available
    plan skip_all => 'Install Selenium::Remote::WDKeys to run this test'
      unless can_load(modules => {'Selenium::Remote::WDKeys' => undef,});

    # wait until the shutdown test is started and hence the test execution paused
    wait_for_developer_console_like($driver, qr/(\"paused\":|\"test_execution_paused\":\".*\")/, 'paused');

    # resume the test execution again
    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');
};

subtest 'schedule job' => sub {
    $driver->get($job_page_url);
    ok wait_for_result_panel($driver, qr/Result: passed/, 'job 1'), 'job 1 passed' or show_job_info 1;
    my $autoinst_log = autoinst_log(1);
    ok -s $autoinst_log, 'autoinst log file generated' or return;
    my $worker_log = $autoinst_log->dirname->child('worker-log.txt');
    ok -s $worker_log, 'worker log file generated';
    my $log_content = $worker_log->slurp;
    like $log_content, qr/Uploading autoinst-log\.txt/, 'autoinst log uploaded';
    like $log_content, qr/Uploading worker-log\.txt/, 'worker log uploaded';
    like $log_content, qr/core-hdd\.qcow2: local upload \(no chunks needed\)/, 'local upload feature used';
    ok -s path($sharedir, 'factory', 'hdd')->make_path->child('core-hdd.qcow2'), 'image of hdd uploaded';
    my $core_hdd_path = path($sharedir, 'factory', 'hdd')->child('core-hdd.qcow2');
    my @core_hdd_stat = stat($core_hdd_path);
    ok @core_hdd_stat, 'can stat ' . $core_hdd_path;
    is S_IMODE($core_hdd_stat[2]), 420, 'exported image has correct permissions (420 -> 0644)';

    my $post_group_res = client_output "-X POST job_groups name='New job group'";
    my $group_id = ($post_group_res =~ qr/id.+([0-9]+)/);
    ok $group_id, 'regular post via client script';
    client_call(qq{-X PUT jobs/1 --json --data '{"group_id":$group_id}'}, qr/job_id.+1/, 'send JSON data via client');
    client_call('jobs/1', qr/group_id.+$group_id/, 'group has been altered correctly');
  }
  or bail_with_log 1,
  'Job 1 produced the wrong results';

subtest 'clone job that crashes' => sub {
    client_call('-X POST jobs/1/restart', qr|test_url.+1.+tests.+2|, 'client returned new test_url for test 2');
    $driver->refresh();
    like status_text, qr/Cloned as 2/, 'test 1 is restarted';
    $driver->click_element_ok('2', 'link_text', 'clicked link to test 2');

    # start a job and stop the worker; the job should be incomplete
    # note: We might not be able to stop the job fast enough so there's a race condition. We could use the pause feature
    #       of the developer mode to prevent that.
    assign_jobs;
    ok wait_for_job_running($driver), 'job 2 running';
    stop_worker;
    ok wait_for_result_panel($driver, qr/Result: incomplete/, 'job 2'), 'job 2 crashed' or show_job_info 2;
    like status_text, qr/Cloned as 3/, 'test 2 is restarted by killing worker';
  }
  or bail_with_log 2,
  'Job 1 produced the wrong results';

subtest 'cancel a scheduled job' => sub {
    client_call(
        '-X POST jobs ' . OpenQA::Test::FullstackUtils::job_setup(MACHINE => 'noassets', HDD_1 => 'nihilist_disk.hda'));

    $driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests');
    wait_for_ajax(msg => 'wait for All Tests displayed before looking for 3');
    $driver->click_element_ok('core@coolone', 'link_text', 'clicked on 3');

    # it can happen that the test is assigned and needs to wait for the scheduler
    # to detect it as dead before it's moved back to scheduled
    ok wait_for_result_panel($driver, qr/State: scheduled/, 'job 3', undef, 0.2), 'Job 3 was scheduled'
      or show_job_info 3;

    my @cancel_button = $driver->find_elements('cancel_running', 'id');
    $cancel_button[0]->click();
  }
  or bail_with_log 3,
  'Job 3 produced the wrong results';

$driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests to go to test 4');
wait_for_ajax(msg => 'wait for All Tests displayed before looking for 3');
$driver->click_element_ok('core@noassets', 'link_text', 'clicked on 4');
$job_name = 'tinycore-1-flavor-i386-Build1-core@noassets';
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
like status_text, qr/State: scheduled/, 'test 4 is scheduled';

ok javascript_console_has_no_warnings_or_errors, 'no javascript warnings or errors after test 4 was scheduled';
start_worker_and_assign_jobs;

subtest 'incomplete job because of setup failure' => sub {
    ok wait_for_result_panel($driver, qr/Result: incomplete/, 'job 4'), 'Job 4 crashed' or show_job_info 4;

    my $autoinst_log = autoinst_log(4);
    wait_for_or_bail_out { -s $autoinst_log } 'autoinst-log.txt';
    my $log_content = $autoinst_log->slurp;
    like $log_content, qr/Result: setup failure/, 'Test 4 result correct: setup failure';
    like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 4 correct autoinst setup notes');
    like((split(/\n/, $log_content))[-1], qr/Uploading autoinst-log.txt/, 'Test 4: upload of autoinst-log.txt logged');
    stop_worker;    # Ensure that the worker can be killed with TERM signal
  }
  or bail_with_log 4,
  'Job 4 produced the wrong results';

my $cache_location = path($ENV{OPENQA_BASEDIR}, 'cache')->make_path;
ok -e $cache_location, 'Setting up Cache directory';

path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt(<<EOC);
[global]
CACHEDIRECTORY = $cache_location
CACHELIMIT = 50
LOCAL_UPLOAD = 0

[1]
WORKER_CLASS = qemu_i386,qemu_x86_64

[http://localhost:$mojoport]
TESTPOOLSERVER = $sharedir/tests
EOC
ok -e path($ENV{OPENQA_CONFIG})->child("workers.ini"), 'Config file created';

# For now let's repeat the cache tests before extracting to separate test
subtest 'Cache tests' => sub {
    my $cache_service = cache_worker_service;
    my $worker_cache_service = cache_minion_worker;

    my $db_file = $cache_location->child('cache.sqlite');
    ok !-e $db_file, 'cache.sqlite is not present';

    my $filename = $cache_location->child('test.file')->spurt('Hello World');
    path($cache_location, 'test_directory')->make_path;

    $worker_cache_service->restart->restart;
    $cache_service->restart->restart;

    my $cache_client = OpenQA::CacheService::Client->new;
    my $supposed_cache_service_host = $cache_client->host;
    wait_for_or_bail_out { $cache_client->info->available } "cache service at $supposed_cache_service_host";
    wait_for_or_bail_out { $cache_client->info->available_workers } 'cache service worker';
    $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
    client_call('-X POST jobs ' . OpenQA::Test::FullstackUtils::job_setup(PUBLISH_HDD_1 => ''));
    $driver->get('/tests/5');
    like status_text, qr/State: scheduled/, 'test 5 is scheduled' or die;
    start_worker_and_assign_jobs;
    ok wait_for_job_running($driver, 1), 'job 5 running' or show_job_info 5;
    ok -e $db_file, 'cache.sqlite file created';
    ok !-d path($cache_location, "test_directory"), 'Directory within cache, not present after deploy';
    ok !-e $cache_location->child("test.file"), 'File within cache, not present after deploy';

    my $link = path($ENV{OPENQA_BASEDIR}, 'openqa', 'pool', '1')->child('Core-7.2.iso');
    wait_for_or_bail_out { -e $link } 'finished download';

    my $cached = $cache_location->child('localhost', 'Core-7.2.iso');
    is $cached->stat->ino, $link->stat->ino, 'iso is hardlinked to cache';

    ok wait_for_result_panel($driver, qr/Result: passed/, 'job 5'), 'job 5 passed' or show_job_info 5;
    stop_worker;
    my $autoinst_log = autoinst_log(5);
    ok -s $autoinst_log, 'Test 5 autoinst-log.txt file created' or return;
    my $log_content = $autoinst_log->slurp;
    like $log_content, qr/Downloading Core-7.2.iso/, 'Test 5, downloaded the right iso';
    like $log_content, qr/11116544/, 'Test 5 Core-7.2.iso size is correct';
    like $log_content, qr/Result: done/, 'Test 5 result done';
    like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 5 correct autoinst setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i,
        'Test 5 correct autoinst uploading autoinst');
    my $worker_log = $autoinst_log->dirname->child('worker-log.txt');
    ok -s $worker_log, 'worker log file generated' or return;
    $log_content = $worker_log->slurp;
    like $log_content, qr/Uploading autoinst-log\.txt/, 'autoinst log uploaded';
    like $log_content, qr/Uploading worker-log\.txt/, 'worker log uploaded';
    unlike $log_content, qr/local upload \(no chunks needed\)/, 'local upload feature not used';
    my $dbh
      = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1});
    my $sql = "SELECT * from assets order by last_use asc";
    my $sth = $dbh->prepare($sql);
    my $result = $dbh->selectrow_hashref($sql);
    # We know it's going to be this host because it's what was defined in
    # the worker ini
    like $result->{filename}, qr/Core-7/, 'Core-7.2.iso is the first element';

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

    $sql = "SELECT * from assets order by last_use desc";
    $sth = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);
    like $result->{filename}, qr/5.qcow2$/, 'file #5 is the newest element';

    # Delete image #5 so that it gets cleaned up when the worker is initialized.
    $sql = "delete from assets where filename = ? ";
    $dbh->prepare($sql)->execute($result->{filename});

    #simple limit testing.
    client_call('-X POST jobs/5/restart', qr|test_url.+5.+tests.+6|, 'client returned new test_url for test 6');
    $driver->get('/tests/6');
    like status_text, qr/State: scheduled/, 'test 6 is scheduled';
    start_worker_and_assign_jobs;
    ok wait_for_result_panel($driver, qr/Result: passed/, 'job 6'), 'job 6 passed' or show_job_info 6;
    stop_worker;
    $autoinst_log = autoinst_log(6);
    ok -s $autoinst_log, 'Test 6 autoinst-log.txt file created' or return;

    ok !-e $result->{filename}, 'asset 5.qcow2 removed during cache init';

    $sql = "SELECT * from assets order by last_use desc";
    $sth = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);
    like $result->{filename}, qr/Core-7/, 'Core-7.2.iso the most recent asset again';

    #simple limit testing.
    client_call('-X POST jobs/6/restart', qr|test_url.+6.+tests.+7|, 'client returned new test_url for test 7');
    $driver->get('/tests/7');
    like status_text, qr/State: scheduled/, 'test 7 is scheduled';
    start_worker_and_assign_jobs;
    ok wait_for_result_panel($driver, qr/Result: passed/, 'job 7'), 'job 7 passed' or show_job_info 7;
    $autoinst_log = autoinst_log(7);
    ok -s $autoinst_log, 'Test 7 autoinst-log.txt file created' or return;
    $log_content = $autoinst_log->slurp;
    like $log_content, qr/\+\+\+\ worker notes \+\+\+/, 'Test 7 has worker notes';
    like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 7 has setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'Test 7 uploaded autoinst-log (as last)');
    client_call('-X POST jobs ' . OpenQA::Test::FullstackUtils::job_setup(HDD_1 => 'non-existent.qcow2'));
    assign_jobs;
    $driver->get('/tests/8');
    ok wait_for_result_panel($driver, qr/Result: incomplete/, 'job 8'), 'job 8 is incomplete' or show_job_info 8;
    like find_status_text($driver), qr/Failed to download.*non-existent.qcow2/, 'reason for incomplete specified';

    subtest 'log shown within details tab (without page reload)' => sub {
        $driver->find_element_by_link_text('Details')->click();
        wait_for_ajax(msg => 'autoinst log embedded within "Details" tab');
        ok my $log = $driver->find_element('.embedded-logfile'), 'element for embedded logfile present';
        wait_for_ajax(msg => 'log contents loaded');
        like($log->get_text(), qr/Result: setup failure/, 'log contents present');
    };

    $autoinst_log = autoinst_log(8);
    ok -s $autoinst_log, 'Test 8 autoinst-log.txt file created' or return;
    $log_content = $autoinst_log->slurp;
    like $log_content, qr/\+\+\+\ worker notes \+\+\+/, 'Test 8 has worker notes';
    like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 8 has setup notes');
    like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'Test 8 uploaded autoinst-log (as last)');
    like $log_content, qr/(Failed to download.*non-existent.qcow2|Download of.*non-existent.qcow2.*failed)/,
      'Test 8 failure message found in log';
    like $log_content, qr/Result: setup failure/, 'Test 8 worker result';
    stop_worker;
  }
  or bail_with_log 8,
  'Job 8 produced the wrong results';

done_testing;

END {
    kill_driver;
    turn_down_stack;
    session->clean;
    $? = 0;
    $tempdir->list_tree->grep(qr/\.txt$/)->each(sub { print "$_:\n" . $_->slurp }) if defined $tempdir;
}
