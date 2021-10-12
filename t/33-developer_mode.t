#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
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
use Test::Mojo;
use IO::Socket::INET;
use Mojo::File 'path';
use POSIX '_exit';
use Fcntl ':mode';
use DBI;
use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Utils qw(service_port);
use OpenQA::Test::Utils qw(
  create_websocket_server create_scheduler create_live_view_handler setup_share_dir setup_fullstack_temp_dir
  start_worker stop_service
);
use OpenQA::Test::FullstackUtils;
use OpenQA::Test::TimeLimit '60';
use OpenQA::SeleniumTest;

plan skip_all => 'set FULLSTACK=1 (be careful)' unless $ENV{FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. "DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

plan skip_all => 'Install Selenium::Remote::WDKeys to run this test'
  unless can_load(modules => {'Selenium::Remote::WDKeys' => undef});

my $worker;
my $ws;
my $livehandler;
my $scheduler;
sub turn_down_stack {
    stop_service($_) for ($worker, $ws, $livehandler, $scheduler);
}

driver_missing unless check_driver_modules;

# setup directories
my $tempdir = setup_fullstack_temp_dir('full-stack.d');
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});
my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok(-d $resultdir, "resultdir \"$resultdir\" exists");

# setup database without fixtures and special admin users 'Demo' and 'otherdeveloper'
my $schema = OpenQA::Test::Database->new->create(schema_name => 'public', drop_schema => 1);
my $users = $schema->resultset('Users');
$users->create(
    {
        username => $_,
        nickname => $_,
        is_operator => 1,
        is_admin => 1,
        feature_version => 0,
    }) for (qw(Demo otherdeveloper));

# make sure the assets are prefetched
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));

# start Selenium test driver and other daemons
my $port = service_port 'webui';
my $driver = call_driver({mojoport => $port});
$ws = create_websocket_server(undef, 0, 0);
$scheduler = create_scheduler;
$livehandler = create_live_view_handler;

# login
$driver->title_is('openQA', 'on main page');
is($driver->find_element('#user-action a')->get_text(), 'Login', 'no one initially logged-in');
$driver->click_element_ok('Login', 'link_text');
$driver->title_is('openQA', 'back on main page');

# setting TESTING_ASSERT_SCREEN_TIMEOUT is important here (see os-autoinst/t/data/tests/tests/boot.pm)
schedule_one_job_over_api_and_verify($driver,
    OpenQA::Test::FullstackUtils::job_setup(TESTING_ASSERT_SCREEN_TIMEOUT => '1'));
my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');
javascript_console_has_no_warnings_or_errors;

my $needle_dir = $sharedir . '/tests/tinycore/needles';

# rename one of the required needle so a certain assert_screen will timeout later
mkdir($needle_dir . '/../disabled_needles');
my $on_prompt_needle = $needle_dir . '/boot-on_prompt';
my $on_prompt_needle_renamed = $needle_dir . '/../disabled_needles/boot-on_prompt';
note('renaming needles for on_prompt to ' . $on_prompt_needle_renamed . '.{json,png}');
for my $ext (qw(.json .png)) {
    ok(-f $on_prompt_needle_renamed . $ext
          or rename($on_prompt_needle . $ext => $on_prompt_needle_renamed . $ext),
        'can rename needle ' . $ext);
}

$worker = start_worker(get_connect_args());
ok wait_for_job_running($driver), 'test 1 is running';

sub wait_for_session_info {
    my ($info_regex, $diag_info) = @_;

    # give the session info 10 seconds to appear
    my $developer_session_info = $driver->find_element('#developer-session-info')->get_text();
    my $waited_s = 0;
    while (!$developer_session_info || !($developer_session_info =~ $info_regex)) {
        # handle case when there's no $developer_session_info at all
        die 'no session info after 10 seconds, expected ' . $diag_info if $waited_s > 10 && !$developer_session_info;
        sleep 1;
        $developer_session_info = $driver->find_element('#developer-session-info')->get_text();
        $waited_s += 1;
    }

    like($developer_session_info, $info_regex, $diag_info);
}

my $developer_console_url = '/tests/1/developer/ws-console?proxy=1';
subtest 'wait until developer console becomes available' => sub {
    $driver->get($developer_console_url);
    wait_for_developer_console_available($driver);
    wait_for_developer_console_like(
        $driver,
        qr/(connected to os-autoinst command server|reusing previous connection to os-autoinst command server)/,
        'proxy says it is connected to os-autoinst cmd srv'
    );
};

my $first_tab = $driver->get_current_window_handle();
my $second_tab;

subtest 'pause at assert_screen timeout' => sub {
    # wait until asserting 'on_prompt'
    wait_for_developer_console_like(
        $driver,
        qr/(\"tags\":\[\"on_prompt\"\]|\"mustmatch\":\"on_prompt\")/,
        'asserting on_prompt'
    );

    # send command to pause on assert_screen timeout
    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"set_pause_on_screen_mismatch","pause_on":"assert_screen"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like(
        $driver,
        qr/\"set_pause_on_screen_mismatch\":\"assert_screen\"/,
        'response to set_pause_on_screen_mismatch'
    );

    # skip timeout
    $command_input->send_keys('{"cmd":"set_assert_screen_timeout","timeout":0}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like(
        $driver,
        qr/\"set_assert_screen_timeout\":0/,
        'response to set_assert_screen_timeout'
    );

    # wait until test paused
    wait_for_developer_console_like(
        $driver,
        qr/\"(reason|test_execution_paused)\":\"match=on_prompt timed out/,
        'paused after assert_screen timeout'
    );

    # try to resume
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');

    # skip timeout (again)
    $command_input->send_keys('{"cmd":"set_assert_screen_timeout","timeout":0}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like(
        $driver,
        qr/\"set_assert_screen_timeout\":0/,
        'response to set_assert_screen_timeout'
    );

    wait_for_developer_console_like($driver, qr/match=on_prompt timed out/, 'paused on assert_screen timeout (again)');
    wait_for_developer_console_like($driver, qr/\"(outstanding_images)\":[1-9]*/, 'progress of image upload received');
    wait_for_developer_console_like($driver, qr/\"(outstanding_images)\":0/, 'image upload has finished');

    # open needle editor in 2nd tab
    my $needle_editor_url = '/tests/1/edit';
    $second_tab = open_new_tab($needle_editor_url);
    $driver->switch_to_window($second_tab);
    $driver->title_is('openQA: Needle Editor');
    my $content = $driver->find_element_by_id('content')->get_text();
    unlike $content, qr/upload.*still in progress/, 'needle editor not available but should be according to progress';
    # check whether screenshot is present
    my $screenshot_url = $driver->execute_script('return window.nEditor.bgImage.src;');
    like $screenshot_url, qr/.*\/boot-[0-9]+\.png/, 'screenshot present';
    $driver->get($screenshot_url);
    is $driver->execute_script('return document.contentType;'), 'image/png', 'URL actually refers to an image';
};

# rename needle back so assert_screen will succeed
for my $ext (qw(.json .png)) {
    ok(rename($on_prompt_needle_renamed . $ext => $on_prompt_needle . $ext), 'can rename back needle ' . $ext);
}

# ensure we're back on the first tab
if ($driver->get_current_window_handle() ne $first_tab) {
    $driver->close();
    $driver->switch_to_window($first_tab);
}

subtest 'pause at certain test' => sub {
    # send command to pause at shutdown (hopefully the test wasn't so fast it is already in shutdown)
    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"set_pause_at_test","name":"shutdown"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"set_pause_at_test\":\"shutdown\"/, 'response to set_pause_at_test');

    # resume test execution (we're still paused from the previous subtest)
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');

    # wait until the shutdown test is started and hence the test execution paused
    wait_for_developer_console_like($driver,
        qr/\"(reason|test_execution_paused)\":\"reached module shutdown\"/, 'paused');
};

sub assert_initial_ui_state {
    $driver->get($job_page_url);
    $driver->find_element_by_link_text('Live View')->click();

    subtest 'initial state of UI controls' => sub {
        wait_for_session_info(qr/owned by Demo/, 'user displayed');
        element_visible('#developer-vnc-notice', qr/.*VNC.*91.*/);
        element_visible('#developer-panel .card-header', qr/paused/);
    };
}

subtest 'developer session visible in live view' => sub {
    assert_initial_ui_state();

    # panel should be expaned by default because we're already owning the session through the developer console
    # and the test is paused
    element_visible(
        '#developer-panel .card-body',
        [qr/Change the test behaviour with the controls below\./, qr/Resume test execution/, qr/Resume/],
        [qr/Confirm to control this test/],
    );

    my @module_options = $driver->find_elements('#developer-pause-at-module option');
    my @module_names = map { $_->get_text() } @module_options;
    is_deeply \@module_names, ['Do not pause at a certain module', 'boot', 'shutdown'], 'module';
};

subtest 'status-only route accessible for other users' => sub {
    $driver->get('/logout');
    $driver->get('/login?user=otherdeveloper');
    is $driver->find_element('#user-action a')->get_text(), 'Logged in as otherdeveloper', 'otherdeveloper logged-in';
    assert_initial_ui_state();

    subtest 'expand developer panel' => sub {
        element_hidden('#developer-panel .card-body');

        $driver->find_element('#developer-status')->click();
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
                qr/Resume/,
            ],
        );
    };
};

subtest 'developer session locked for other developers' => sub {
    $driver->get($developer_console_url);

    wait_for_developer_console_like($driver, qr/unable to create \(further\).*session/, 'no further session');
    wait_for_developer_console_like($driver, qr/Connection closed/, 'closed');
};

$second_tab = open_new_tab('/login?user=Demo');

subtest 'connect with 2 clients at the same time (use case: developer opens 2nd tab)' => sub {
    $driver->switch_to_window($second_tab);
    $driver->get($developer_console_url);

    wait_for_developer_console_like($driver, qr/Connection opened/, 'connection opened');
    wait_for_developer_console_like($driver, qr/reusing previous connection to os-autoinst/, 'connection reused');
};

subtest 'resume test execution and 2nd tab' => sub {
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
    wait_for_developer_console_like($driver, qr/Connection opened/, 'connection opened');

    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"resume_test_execution"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume');

    # check whether info has also been distributed to 2nd tab
    $driver->switch_to_window($second_tab);
    wait_for_developer_console_like($driver, qr/\"resume_test_execution\":/, 'resume (2nd tab)');
};

subtest 'quit session' => sub {
    $driver->switch_to_window($first_tab);

    my $command_input = $driver->find_element('#msg');
    $command_input->send_keys('{"cmd":"quit_development_session"}');
    $command_input->send_keys(Selenium::Remote::WDKeys->KEYS->{'enter'});
    wait_for_developer_console_like($driver, qr/Connection closed/, 'closed');

    # check whether 2nd client has been kicked out as well
    $driver->switch_to_window($second_tab);
    wait_for_developer_console_like($driver, qr/Connection closed/, 'closed (2nd tab)');
};

subtest 'test cancelled by quitting the session' => sub {
    $driver->switch_to_window($first_tab);
    $driver->get($job_page_url);
    ok wait_for_result_panel($driver, qr/(State: cancelled|Result: (user_cancelled|passed))/),
      'test 1 has been cancelled (if it was fast enough to actually pass that is ok, too)';
    my $log_file_path = path($resultdir, '00000', "00000001-$job_name")->make_path->child('autoinst-log.txt');
    ok -s $log_file_path, "log file generated under $log_file_path";
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
