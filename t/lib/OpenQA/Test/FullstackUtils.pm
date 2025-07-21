# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::FullstackUtils;

use Test::Most;
use Mojo::Base 'Exporter', -signatures;

our @EXPORT = qw(get_connect_args client_output client_call prevent_reload
  reload_manually find_status_text wait_for_result_panel
  wait_for_job_running wait_for_developer_console_like
  wait_for_developer_console_available enter_developer_console_cmd
  verify_one_job_displayed_as_scheduled
  schedule_one_job_over_api_and_verify);

use Mojolicious;
use Mojo::Home;
use Time::HiRes 'sleep';
use Time::Seconds;
use OpenQA::SeleniumTest;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Test::TimeLimit ();
use OpenQA::Test::Utils 'wait_for_or_bail_out';

my $JOB_SETUP = {
    ISO => 'Core-7.2.iso',
    DISTRI => 'tinycore',
    ARCH => 'i386',
    QEMU => 'i386',
    FLAVOR => 'flavor',
    BUILD => '1',
    MACHINE => 'coolone',
    QEMU_NO_TABLET => '1',
    INTEGRATION_TESTS => '1',
    QEMU_NO_FDC_SET => '1',
    VERSION => '1',
    TEST => 'core',
    PUBLISH_HDD_1 => 'core-hdd.qcow2',
    UEFI_PFLASH_VARS => '/usr/share/qemu/ovmf-x86_64.bin'
};

# speedup using virtualization support if available, results should be
# equivalent, just saving some time
$JOB_SETUP->{QEMU_NO_KVM} = '1' unless -r '/dev/kvm';

sub job_setup (%override) {
    my $new = {%$JOB_SETUP, %override};
    return join ' ', map { "$_=$new->{$_}" } sort keys %$new;
}

sub get_connect_args () {
    my $mojoport = OpenQA::SeleniumTest::get_mojoport;
    return ['--apikey=1234567890ABCDEF', '--apisecret=1234567890ABCDEF', "--host=http://localhost:$mojoport"];
}

sub client_output ($args) { qx{perl ./script/openqa-cli api @{get_connect_args()} $args} }

sub client_call ($args, $expected_out = undef, $desc = 'client_call') {
    my $out = client_output $args;
    return undef unless $expected_out;
    like($out, $expected_out, $desc) or die;
}

sub find_status_text ($driver) {
    # query text via JavaScript because when using `$driver->find_element('#info_box .card-body')->get_text`
    # the element might be swapped out by the page's JavaScript under the hood after it has been returned by
    # `find_element` and before the text is queried via `get_text` leading to the error `getElementText: stale
    # element reference: element is not attached to the page document`
    $driver->execute_script('return document.querySelector("#info_box .card-body").innerText');
}

# uncoverable statement
sub _fail_with_result_panel_contents ($result_panel_contents, $msg) {
    diag("full result panel contents:\n$result_panel_contents");    # uncoverable statement
    ok(javascript_console_has_no_warnings_or_errors, 'No unexpected js warnings');    # uncoverable statement
    fail 'Expected result not found';    # uncoverable statement
}

sub wait_for_result_panel ($driver, $result_panel, $context = undef, $fail_on_incomplete = undef, $check_interval = 0.5)
{
    my $looking_for_result = $result_panel =~ qr/Result: /;
    $context //= 'current job';
    my $msg = "Expected result for $context not found";

    my $timeout = OpenQA::Test::TimeLimit::scale_timeout(30) / $check_interval;
    for (my $count = 0; $count < $timeout; $count++) {
        wait_for_ajax(msg => "wait_for_result_panel: waiting for '$result_panel' (count $count of $timeout)");
        my $status_text = find_status_text($driver);
        return 1 if $status_text =~ $result_panel;
        if ($fail_on_incomplete && $status_text =~ qr/Result: (incomplete|timeout_exceeded)/) {
            diag('test result is incomplete but shouldn\'t');    # uncoverable statement
            return _fail_with_result_panel_contents($status_text, $msg);    # uncoverable statement
        }
        if ($looking_for_result && $status_text =~ qr/Result: (.*) finished/) {
            diag("stopped waiting for '$result_panel', result turned out to be '$1'");    # uncoverable statement
            return _fail_with_result_panel_contents($status_text, $msg);    # uncoverable statement
        }
        return _fail_with_result_panel_contents($status_text, $msg)
          unless javascript_console_has_no_warnings_or_errors;    # uncoverable statement
        sleep $check_interval if $check_interval;
    }
    my $final_status_text = find_status_text($driver);    # uncoverable statement
    return 1 if $final_status_text =~ $result_panel;    # uncoverable statement
    return _fail_with_result_panel_contents($final_status_text, $msg);    # uncoverable statement
}

sub wait_for_job_running ($driver, $fail_on_incomplete = undef) {
    my $success = wait_for_result_panel($driver, qr/State: running/, $fail_on_incomplete);
    return unless $success;
    wait_for_element(selector => '#nav-item-for-live')->click();
}

# matches a regex; returns the index of the end of the match on success and otherwise -1
# note: using a separate function here because $+[0] is not accessible from outer block when used in while
sub _match_regex_returning_index ($regex, $message, $start_index = 0) {
    (substr($message, $start_index) =~ $regex) ? $+[0] : -1;
}

# waits until the developer console content matches the specified regex
# note: only considers the console output since the last successful call
sub wait_for_developer_console_like ($driver, $message_regex, $diag_info, $timeout_s = ONE_MINUTE * 2) {
    my $js_erro_check_suffix = ', waiting for ' . $diag_info;
    ok(javascript_console_has_no_warnings_or_errors($js_erro_check_suffix), 'No unexpected js warnings');

    # get log
    my $position_of_last_match = $driver->execute_script('return window.lastWaitForDevelConsoleMsgMatch;') // 0;
    my $log_textarea = $driver->find_element('#log');
    my $log = $log_textarea->get_text();
    my $previous_log = '';
    # poll less frequently when waiting for paused (might take a minute for the first test module to pass)
    my $check_interval = $diag_info eq 'paused' ? 5 : 1;
    my $timeout = OpenQA::Test::TimeLimit::scale_timeout($timeout_s);

    my $match_index;
    while (($match_index = _match_regex_returning_index($message_regex, $log, $position_of_last_match)) < 0) {
        return fail("Wait for $message_regex timed out") if $timeout <= 0;

        $timeout -= $check_interval;
        sleep($check_interval);

        # print updated log so we see what's going on
        note("waiting for $diag_info, developer console contains:\n$log") if $log ne $previous_log;
        wait_for_ajax(msg => $message_regex . " remaining wait time ${timeout}s");
        javascript_console_has_no_warnings_or_errors($js_erro_check_suffix) or return;
        $previous_log = $log;
        $log = $log_textarea->get_text();
    }

    $position_of_last_match += $match_index;
    $driver->execute_script("window.lastWaitForDevelConsoleMsgMatch = $position_of_last_match;");
    pass("found $diag_info at $position_of_last_match");
}

sub wait_for_developer_console_available ($driver) {
    wait_for_or_bail_out {
        note('waiting for worker to propagate URL for os-autoinst cmd srv');
        $driver->refresh;
        wait_for_ajax(msg => 'developer console available');
        my $console_form = $driver->find_element('#ws_console_form');
        my $text = $console_form->get_text() // '';
        return $text =~ qr/The command server is not available./ ? 0 : 1;
    }
    'URL for os-autoinst cmd srv', {timeout => 120, interval => 2};

    # check initial connection
    wait_for_developer_console_like($driver, qr/Connection opened/, 'connection opened');
}

sub enter_developer_console_cmd ($driver, $cmd) {
    $driver->execute_script("document.getElementById('msg').value = '$cmd';");
    $driver->execute_script('submitWebSocketCommand();');
}

sub verify_one_job_displayed_as_scheduled ($driver) {
    $driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests to look for scheduled job');
    $driver->title_is('openQA: Test results', 'tests followed');
    wait_for_ajax(msg => 'wait before checking for scheduled job');
    return $driver->find_element_by_id('scheduled_jobs_heading')->get_text() eq '1 scheduled jobs';
}

sub schedule_one_job_over_api_and_verify ($driver, $job_setup) {
    client_call("-X POST jobs $job_setup");
    return verify_one_job_displayed_as_scheduled($driver);
}

1;
