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

use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use List::Util ();
use Test::Mojo;
use Test::MockModule;
use Test::Exception;
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
$driver->click_element_ok('shepherd-cancel-icon', 'class_name', 'confirm dismissing tour');

schedule_one_job_over_api_and_verify($driver, OpenQA::Test::FullstackUtils::job_setup(PAUSE_AT => 'shutdown'));

sub status_text { find_status_text($driver) }

# add a function to verify the test setup before trying to run a job
my $setup_timeout = 0;    # actually initialized further down after subtest 'testhelper'
my $setup_poll_interval = 0;    # actually initialized further down after subtest 'testhelper'
sub check_scheduled_job_and_wait_for_free_worker ($worker_class) {
    # check whether the job we expect to be scheduled is actually scheduled
    # note: After all this is a test so it might uncover problems and then it is useful to have further
    #       information to know what's wrong.
    my @scheduled_jobs = values %{OpenQA::Scheduler::Model::Jobs->singleton->determine_scheduled_jobs};
    my $relevant_jobs = 0;
    for my $job (@scheduled_jobs) {
        ++$relevant_jobs if List::Util::any { $_ eq $worker_class } @{$job->{worker_classes}};
    }
    Test::More::ok $relevant_jobs, "$relevant_jobs job(s) with worker class $worker_class scheduled"
      or Test::More::diag explain 'scheduled jobs: ', \@scheduled_jobs;

    # wait until there's not only a free worker but also one with matching worker properties
    # note: Populating the database is not done atomically so a worker might already show up but relevant
    #       properties (most importantly WEBSOCKET_API_VERSION and WORKER_CLASS) have not been populated yet.
    my ($elapsed, $free_workers) = (0, []);
    for (; $elapsed <= $setup_timeout; $elapsed += sleep $setup_poll_interval) {
        for my $worker (@{$free_workers = OpenQA::Scheduler::Model::Jobs::determine_free_workers}) {
            next unless $worker->check_class($worker_class);
            pass "at least one free worker with class $worker_class registered";
            return ($relevant_jobs, $elapsed);
        }
    }
    Test::More::fail "no worker with class $worker_class showed up after $elapsed seconds";
    Test::More::diag explain 'free workers: ', [map { $_->info } @$free_workers];
    return ($relevant_jobs, $elapsed);
}

sub show_job_info ($job_id) {
    my $job = $schema->resultset('Jobs')->find($job_id);
    Test::More::diag explain 'job info: ', $job ? $job->to_hash : undef;
}

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like(status_text, qr/State: scheduled/, 'test 1 is scheduled');
ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings after test 1 was scheduled');

sub assign_jobs ($worker_class = undef) {
    my ($to_be_scheduled, $elapsed) = check_scheduled_job_and_wait_for_free_worker $worker_class // 'qemu_i386';
    my $scheduler = OpenQA::Scheduler::Model::Jobs->singleton;
    for (; $elapsed <= $setup_timeout; $elapsed += sleep $setup_poll_interval) {
        return if @{$scheduler->schedule} >= $to_be_scheduled;
    }
    fail "Unable to assign $to_be_scheduled jobs after $elapsed seconds";    # uncoverable statement
}
sub start_worker_and_assign_jobs ($worker_class = undef) {
    $worker = start_worker get_connect_args;
    ok $worker, "Worker started as $worker";
    assign_jobs $worker_class;
}

sub logfile ($job_id, $filename) {
    my $log = path($resultdir, '00000', sprintf("%08d-$job_name", $job_id))->child($filename);
    return -e $log ? $log : path("$resultdir/../pool/1/")->child($filename);
}

sub print_log ($job_id) {
    for (qw(autoinst-log.txt worker-log.txt)) {
        my $log_file = logfile($job_id, $_);
        my $log = eval { $log_file->slurp };
        Test::More::diag $@ ? "unable to read $log_file: $@" : "$log_file:\n$log";
    }
}

sub bail_with_log ($job_id, $message) {
    print_log $job_id;
    Test::More::BAIL_OUT $message;
}

subtest 'testhelper' => sub {
    my ($bailout_msg, $fail_msg);
    my $test_most_mock = Test::MockModule->new('Test::More');
    $test_most_mock->noop('diag');
    $test_most_mock->redefine(BAIL_OUT => sub ($msg, @) { $bailout_msg = $msg });
    bail_with_log 42, 'foo';
    is $bailout_msg, 'foo', 'BAIL_OUT invoked';

    $test_most_mock->redefine(fail => sub ($msg, @) { $fail_msg = $msg });
    $test_most_mock->redefine(ok => 0);
    check_scheduled_job_and_wait_for_free_worker 'bar';
    like $fail_msg, qr/no worker with class bar showed up after .* seconds/, 'fail invoked';

    lives_ok { show_job_info(42) } 'helper for showing job info';
};

$setup_timeout = OpenQA::Test::TimeLimit::scale_timeout($ENV{OPENQA_FULLSTACK_SETUP_TIMEOUT} // 2);
$setup_poll_interval = $ENV{OPENQA_FULLSTACK_SETUP_POLL_INTERVAL} // 0.1;

start_worker_and_assign_jobs;
ok wait_for_job_running($driver, 1), 'test 1 is running' or bail_with_log 1, 'unable to run test 1';

subtest 'wait until developer console becomes available' => sub {
    # open developer console
    $driver->get('/tests/1/developer/ws-console');
    wait_for_developer_console_available($driver);
};

subtest 'pause at certain test' => sub {
    # wait until the shutdown test is started and hence the test execution paused
    wait_for_developer_console_like($driver, qr/(\"paused\":|\"test_execution_paused\":\".*\")/, 'paused');

    # resume the test execution again
    enter_developer_console_cmd $driver, '{"cmd":"resume_test_execution"}';
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');
};

subtest 'schedule job' => sub {
    $driver->get($job_page_url);
    ok wait_for_result_panel($driver, qr/Result: passed/, 'job 1'), 'job 1 passed' or show_job_info 1;
    my $autoinst_log = logfile(1, 'autoinst-log.txt');
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

ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings after test 4 was scheduled');
start_worker_and_assign_jobs;

subtest 'incomplete job because of setup failure' => sub {
    ok wait_for_result_panel($driver, qr/Result: incomplete/, 'job 4'), 'Job 4 crashed' or show_job_info 4;

    my $autoinst_log = logfile(4, 'autoinst-log.txt');
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

path($ENV{OPENQA_CONFIG})->child("workers.ini")->spew(<<EOC);
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

    my $filename = $cache_location->child('test.file')->spew('Hello World');
    path($cache_location, 'test_directory')->make_path;

    $worker_cache_service->restart->restart;
    $cache_service->restart->restart;

    my %dbi_params = (RaiseError => 1, PrintError => 1, AutoCommit => 1);
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, \%dbi_params);

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
    my $result_5;
    subtest 'results of test 5' => sub {
        ok -e $db_file, 'cache.sqlite file created';
        ok !-d path($cache_location, "test_directory"), 'Directory within cache, not present after deploy';
        ok !-e $cache_location->child("test.file"), 'File within cache, not present after deploy';

        my $link = path($ENV{OPENQA_BASEDIR}, 'openqa', 'pool', '1')->child('Core-7.2.iso');
        wait_for_or_bail_out { -e $link } 'finished download';

        my $cached = $cache_location->child('localhost', 'Core-7.2.iso');
        is $cached->stat->ino, $link->stat->ino, 'iso is hardlinked to cache';

        ok wait_for_result_panel($driver, qr/Result: passed/, 'job 5'), 'job 5 passed' or show_job_info 5;
        stop_worker;
        my $autoinst_log = logfile(5, 'autoinst-log.txt');
        ok -s $autoinst_log, 'Test 5 autoinst-log.txt file created' or return;
        my $log_content = $autoinst_log->slurp;
        like $log_content, qr/Downloading Core-7.2.iso/, 'Test 5, downloaded the right iso';
        like $log_content, qr/11116544/, 'Test 5 Core-7.2.iso size is correct';
        like $log_content, qr/Result: done/, 'Test 5 result done';
        like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'setup notes present');
        like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'uploading of autoinst-log.txt logged');
        my $worker_log = $autoinst_log->dirname->child('worker-log.txt');
        ok -s $worker_log, 'worker log file generated' or return;
        $log_content = $worker_log->slurp;
        like $log_content, qr/Uploading autoinst-log\.txt/, 'autoinst log uploaded';
        like $log_content, qr/Uploading worker-log\.txt/, 'worker log uploaded';
        unlike $log_content, qr/local upload \(no chunks needed\)/, 'local upload feature not used';
        $result_5 = $dbh->selectrow_hashref('SELECT * from assets order by last_use asc');
        # We know it's going to be this host because it's what was defined in
        # the worker ini
        like $result_5->{filename}, qr/Core-7/, 'Core-7.2.iso is the first element';

        # create assets at same time and in the following seconds after the above
        my $time = $result_5->{last_use};
        for (1 .. 5) {
            $filename = $cache_location->child("$_.qcow2");
            path($filename)->spew($filename);
            # so that last_use is not the same for every item
            $time++;
            my $sth = $dbh->prepare("INSERT INTO assets (filename,etag,last_use) VALUES ( ?, 'Not valid', $time);");
            $sth->bind_param(1, $filename);
            $sth->execute();
        }

        $result_5 = $dbh->selectrow_hashref('SELECT * from assets order by last_use desc');
        like $result_5->{filename}, qr/5.qcow2$/, 'file #5 is the newest element';

        # Delete image #5 so that it gets cleaned up when the worker is initialized.
        $dbh->prepare('delete from assets where filename = ? ')->execute($result_5->{filename});
    } or print_log 5;

    #simple limit testing.
    client_call('-X POST jobs/5/restart', qr|test_url.+5.+tests.+6|, 'client returned new test_url for test 6');
    $driver->get('/tests/6');
    like status_text, qr/State: scheduled/, 'test 6 is scheduled';
    start_worker_and_assign_jobs;
    subtest 'results of test 6' => sub {
        ok wait_for_result_panel($driver, qr/Result: passed/, 'job 6'), 'job 6 passed' or show_job_info 6;
        stop_worker;
        my $autoinst_log = logfile(6, 'autoinst-log.txt');
        ok -s $autoinst_log, 'Test 6 autoinst-log.txt file created' or return;
        ok !-e $result_5->{filename}, 'asset 5.qcow2 removed during cache init' if ref $result_5 eq 'HASH';
        my $result = $dbh->selectrow_hashref('SELECT * from assets order by last_use desc');
        like $result->{filename}, qr/Core-7/, 'Core-7.2.iso the most recent asset again';
    } or print_log 6;

    #simple limit testing.
    client_call('-X POST jobs/6/restart', qr|test_url.+6.+tests.+7|, 'client returned new test_url for test 7');
    $driver->get('/tests/7');
    like status_text, qr/State: scheduled/, 'test 7 is scheduled';
    start_worker_and_assign_jobs;
    subtest 'results of test 7' => sub {
        ok wait_for_result_panel($driver, qr/Result: passed/, 'job 7'), 'job 7 passed' or show_job_info 7;
        my $autoinst_log = logfile(7, 'autoinst-log.txt');
        ok -s $autoinst_log, 'Test 7 autoinst-log.txt file created' or return;
        my $log_content = $autoinst_log->slurp;
        like $log_content, qr/\+\+\+\ worker notes \+\+\+/, 'Test 7 has worker notes';
        like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'setup notes present');
        like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'uploaded autoinst-log');
    } or print_log 7;

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

    subtest 'results of test 8' => sub {
        my $autoinst_log = logfile(8, 'autoinst-log.txt');
        ok -s $autoinst_log, 'autoinst-log.txt file created' or return;
        my $log_content = $autoinst_log->slurp;
        like $log_content, qr/\+\+\+\ worker notes \+\+\+/, 'worker notes present';
        like((split(/\n/, $log_content))[0], qr/\+\+\+ setup notes \+\+\+/, 'setup notes present');
        like((split(/\n/, $log_content))[-1], qr/uploading autoinst-log.txt/i, 'autoinst-log uploaded');
        like $log_content, qr/(Failed to download.*non-existent.qcow2|Download of.*non-existent.qcow2.*failed)/,
          'failure message found in log';
        like $log_content, qr/Result: setup failure/, 'job result result';
    } or print_log 8;

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
