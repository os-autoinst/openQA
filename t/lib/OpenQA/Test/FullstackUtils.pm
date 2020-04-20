# Copyright (C) 2018-2020 SUSE LLC
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

use strict;
use warnings;

use base 'Exporter';

use Mojolicious;
use Mojo::Home;
use Test::More;
use Time::HiRes 'sleep';
use OpenQA::SeleniumTest;
use OpenQA::Scheduler::Model::Jobs;

our $JOB_SETUP
  = 'ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
  . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 INTEGRATION_TESTS=1 '
  . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2 '
  . 'UEFI_PFLASH_VARS=/usr/share/qemu/ovmf-x86_64.bin';

# speedup using virtualization support if available, results should be
# equivalent, just saving some time
$JOB_SETUP .= ' QEMU_NO_KVM=1' unless -r '/dev/kvm';

sub get_connect_args {
    my $mojoport = OpenQA::SeleniumTest::get_mojoport;
    return "--apikey=1234567890ABCDEF --apisecret=1234567890ABCDEF --host=http://localhost:$mojoport";
}

sub client_output {
    my ($args) = @_;
    my $connect_args = get_connect_args();
    open(my $client, "-|", "perl ./script/client $connect_args $args");
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

# prevents the page to reload itself (useful because elements are invalidated on reload which is hard to handle)
sub prevent_reload {
    my ($driver) = @_;

    $driver->execute_script(
        q/
        window.reloadPage = function() {
            window.wouldHaveReloaded = true;
            console.log("Page reload prevented");
        };
    /
    );
}

# reloads the page manually and prevents further automatic reloads
sub reload_manually {
    my ($driver, $desc, $delay) = @_;

    sleep($delay) if $delay;
    if ($driver->execute_script('return window.wouldHaveReloaded;')) {
        note("reloading manually ($desc)");
        $driver->refresh();
    }
    prevent_reload($driver);
}

sub find_status_text { shift->find_element('#result-row .card-body')->get_text() }

sub wait_for_result_panel {
    my ($driver, $result_panel, $desc, $fail_on_incomplete, $refresh_interval) = @_;
    $refresh_interval //= 1;

    prevent_reload($driver);

    for (my $count = 0; $count < ((3 * 60) / $refresh_interval); $count++) {
        my $status_text = find_status_text($driver);
        last if ($status_text =~ $result_panel);
        if ($fail_on_incomplete && $status_text =~ qr/Result: (incomplete|timeout_exceeded)/) {
            fail('test result is incomplete but shouldn\'t');
            return;
        }
        javascript_console_has_no_warnings_or_errors;
        reload_manually($driver, $desc, $refresh_interval);
    }
    javascript_console_has_no_warnings_or_errors;
    reload_manually($driver, $desc);
    like(find_status_text($driver), $result_panel, $desc);
}

sub wait_for_job_running {
    my ($driver, $fail_on_incomplete) = @_;
    wait_for_result_panel($driver, qr/State: running/, 'job is running', $fail_on_incomplete);
    $driver->find_element_by_link_text('Live View')->click();
}

# matches a regex; returns the index of the end of the match on success and otherwise -1
# note: using a separate function here because $+[0] is not accessible from outer block when used in while
sub match_regex_returning_index {
    my ($regex, $message, $start_index) = @_;
    $start_index //= 0;

    return $+[0] if (substr($message, $start_index) =~ $regex);
    return -1;
}

# waits until the developer console content matches the specified regex
# note: only considers the console output since the last successful call
sub wait_for_developer_console_contains_log_message {
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
    my $timeout        = 60 * 5 * $check_interval;

    my $match_index;
    while (($match_index = match_regex_returning_index($message_regex, $log, $position_of_last_match)) < 0) {
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

    my $console_form = $driver->find_element('#ws_console_form');
    my $text         = $console_form->get_text();

    # give the worker 1 minute to tell us the URL for os-autoinst command server
    my $seconds = 0;
    while ($text =~ qr/The command server is not available./) {
        if ($seconds >= 60) {
            fail('worker did not propagate URL for os-autoinst cmd srv within 1 minute');
            return;
        }

        print(" - waiting for worker to propagate URL for os-autoinst cmd srv\n");
        sleep 2;

        # reload the page, read text again
        $driver->get($driver->get_current_url());
        $console_form = $driver->find_element('#ws_console_form');
        $text         = $console_form->get_text();
        $seconds += 1;
    }
    pass("os-autoinst cmd srv available after $seconds seconds");

    # check initial connection
    OpenQA::Test::FullstackUtils::wait_for_developer_console_contains_log_message(
        $driver,
        qr/Connection opened/,
        'connection opened'
    );
}

sub schedule_one_job {
    until (OpenQA::Scheduler::Model::Jobs->singleton->schedule) { sleep .1 }
}

sub verify_one_job_displayed_as_scheduled {
    my ($driver) = @_;

    $driver->click_element_ok('All Tests', 'link_text', 'Clicked All Tests to look for scheduled job');
    $driver->title_is('openQA: Test results', 'tests followed');
    my $msg = 'test displayed as scheduled';
    wait_for_ajax(msg => $msg);
    is $driver->find_element_by_id('scheduled_jobs_heading')->get_text(), '1 scheduled jobs', $msg;
}

sub schedule_one_job_over_api_and_verify {
    my ($driver) = @_;
    client_call("jobs post $JOB_SETUP");
    return verify_one_job_displayed_as_scheduled($driver);
};

1;
