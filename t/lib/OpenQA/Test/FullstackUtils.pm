# Copyright (C) 2018-2021 SUSE LLC
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

package OpenQA::Test::FullstackUtils;

use Test::Most;

use base 'Exporter';

our @EXPORT = qw(get_connect_args client_output client_call prevent_reload
  reload_manually find_status_text wait_for_result_panel
  wait_for_job_running wait_for_developer_console_like
  wait_for_developer_console_available
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
    ISO               => 'Core-7.2.iso',
    DISTRI            => 'tinycore',
    ARCH              => 'i386',
    QEMU              => 'i386',
    FLAVOR            => 'flavor',
    BUILD             => '1',
    MACHINE           => 'coolone',
    QEMU_NO_TABLET    => '1',
    INTEGRATION_TESTS => '1',
    QEMU_NO_FDC_SET   => '1',
    VERSION           => '1',
    TEST              => 'core',
    PUBLISH_HDD_1     => 'core-hdd.qcow2',
    UEFI_PFLASH_VARS  => '/usr/share/qemu/ovmf-x86_64.bin'
};

# speedup using virtualization support if available, results should be
# equivalent, just saving some time
$JOB_SETUP->{QEMU_NO_KVM} = '1' unless -r '/dev/kvm';

sub job_setup {
    my %override = @_;
    my $new      = {%$JOB_SETUP, %override};
    return join ' ', map { "$_=$new->{$_}" } sort keys %$new;
}

sub get_connect_args {
    my $mojoport = OpenQA::SeleniumTest::get_mojoport;
    return ["--apikey=1234567890ABCDEF", "--apisecret=1234567890ABCDEF", "--host=http://localhost:$mojoport"];
}

sub client_output {
    my ($args) = @_;
    my @connect_args = @{get_connect_args()};
    open(my $client, "-|", "perl ./script/openqa-cli api @connect_args $args");
    my $out;
    while (<$client>) {
        $out .= $_;
    }
    close($client);
    return $out;
}

sub client_call {
    my ($args, $expected_out, $desc) = @_;
    my $out = client_output $args;
    if ($expected_out) {
        like($out, $expected_out, $desc) or die;
    }
}

sub find_status_text { shift->find_element('#info_box .card-body')->get_text() }

sub _bail_with_result_panel_contents {
    my ($result_panel_contents) = @_;
    diag("full result panel contents:\n$result_panel_contents");
    javascript_console_has_no_warnings_or_errors;
    BAIL_OUT "Expected result not found";    # uncoverable statement
}

sub wait_for_result_panel {
    my ($driver, $result_panel, $fail_on_incomplete, $check_interval) = @_;
    my $looking_for_result = $result_panel =~ qr/Result: /;
    $check_interval //= 0.5;

    my $timeout = OpenQA::Test::TimeLimit::scale_timeout(ONE_MINUTE * 3) / $check_interval;
    for (my $count = 0; $count < $timeout; $count++) {
        wait_for_ajax(msg => "result panel shows '$result_panel'");
        my $status_text = find_status_text($driver);
        return 1 if $status_text =~ $result_panel;
        if ($fail_on_incomplete && $status_text =~ qr/Result: (incomplete|timeout_exceeded)/) {
            diag('test result is incomplete but shouldn\'t');
            return _bail_with_result_panel_contents $status_text;
        }
        if ($looking_for_result && $status_text =~ qr/Result: (.*) finished/) {
            diag("stopped waiting for '$result_panel', result turned out to be '$1'");
            return _bail_with_result_panel_contents $status_text;
        }
        javascript_console_has_no_warnings_or_errors;
        sleep $check_interval if $check_interval;
    }
    my $final_status_text = find_status_text($driver);
    return 1 if $final_status_text =~ $result_panel;
    return _bail_with_result_panel_contents $final_status_text;
}

sub wait_for_job_running {
    my ($driver, $fail_on_incomplete) = @_;
    my $success = wait_for_result_panel($driver, qr/State: running/, $fail_on_incomplete);
    return unless $success;
    wait_for_element(selector => '#nav-item-for-live')->click();
}

# matches a regex; returns the index of the end of the match on success and otherwise -1
# note: using a separate function here because $+[0] is not accessible from outer block when used in while
sub _match_regex_returning_index {
    my ($regex, $message, $start_index) = @_;
    $start_index //= 0;

    return $+[0] if (substr($message, $start_index) =~ $regex);
    return -1;
}

# waits until the developer console content matches the specified regex
# note: only considers the console output since the last successful call
sub wait_for_developer_console_like {
    my ($driver, $message_regex, $diag_info) = @_;

    # abort on javascript console errors
    my $js_erro_check_suffix = ', waiting for ' . $diag_info;
    javascript_console_has_no_warnings_or_errors($js_erro_check_suffix);

    # get log
    my $position_of_last_match = $driver->execute_script('return window.lastWaitForDevelConsoleMsgMatch;') // 0;
    my $log_textarea           = $driver->find_element('#log');
    my $log                    = $log_textarea->get_text();
    my $previous_log           = '';
    # poll less frequently when waiting for paused (might take a minute for the first test module to pass)
    my $check_interval = $diag_info eq 'paused' ? 5 : 1;
    my $timeout        = OpenQA::Test::TimeLimit::scale_timeout(ONE_MINUTE * 5) * $check_interval;

    my $match_index;
    while (($match_index = _match_regex_returning_index($message_regex, $log, $position_of_last_match)) < 0) {
        if ($timeout <= 0) {
            fail("Wait for $message_regex timed out");
            return undef;
        }

        $timeout -= $check_interval;
        sleep($check_interval);

        # print updated log so we see what's going on
        if ($log ne $previous_log) {
            note("waiting for $diag_info, developer console contains:\n$log");
        }

        wait_for_ajax(msg => $message_regex);
        javascript_console_has_no_warnings_or_errors($js_erro_check_suffix) or return;
        $previous_log = $log;
        $log          = $log_textarea->get_text();
    }

    $position_of_last_match += $match_index;
    $driver->execute_script("window.lastWaitForDevelConsoleMsgMatch = $position_of_last_match;");
    pass("found $diag_info at $position_of_last_match");
}

sub wait_for_developer_console_available {
    my ($driver) = @_;

    wait_for_or_bail_out {
        note('waiting for worker to propagate URL for os-autoinst cmd srv');
        $driver->refresh;
        wait_for_ajax(msg => 'developer console available');
        my $console_form = $driver->find_element('#ws_console_form');
        my $text         = $console_form->get_text() // '';
        return $text =~ qr/The command server is not available./ ? 0 : 1;
    }
    'URL for os-autoinst cmd srv', {timeout => 120, interval => 2};

    # check initial connection
    wait_for_developer_console_like($driver, qr/Connection opened/, 'connection opened');
}

sub verify_one_job_displayed_as_scheduled {
    my ($driver) = @_;

    $driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests to look for scheduled job');
    $driver->title_is('openQA: Test results', 'tests followed');
    wait_for_ajax(msg => 'wait before checking for scheduled job');
    return $driver->find_element_by_id('scheduled_jobs_heading')->get_text() eq '1 scheduled jobs';
}

sub schedule_one_job_over_api_and_verify {
    my ($driver, $job_setup) = @_;
    client_call("-X POST jobs $job_setup");
    return verify_one_job_displayed_as_scheduled($driver);
}

1;
