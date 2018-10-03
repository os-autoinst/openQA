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

package OpenQA::Test::FullstackUtils;
use base 'Exporter';
use Mojolicious;
use Mojo::Home;
use Mojo::File qw(path tempdir);
use Test::More;
use OpenQA::SeleniumTest;

sub setup_database {
    # make database configuration
    path($ENV{OPENQA_CONFIG})->child('database.ini')->to_string;
    ok(-e path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->child('db.lock'));
    ok(open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child('database.ini')->to_string));
    print $conf <<"EOC";
    [production]
    dsn = $ENV{TEST_PG}
EOC
    close($conf);

    # drop the schema from the existant database, init a new, empty database
    my $dbh = DBI->connect($ENV{TEST_PG});
    $dbh->do('SET client_min_messages TO WARNING;');
    $dbh->do('drop schema if exists public cascade;');
    $dbh->do('CREATE SCHEMA public;');
    $dbh->disconnect;
    is(system('perl ./script/initdb --init_database'), 0, 'init empty database');
}

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

sub wait_for_result_panel {
    my ($driver, $result_panel, $desc, $fail_on_incomplete, $refresh_interval) = @_;
    $refresh_interval //= 1;

    prevent_reload($driver);

    for (my $count = 0; $count < ((10 * 60) / $refresh_interval); $count++) {
        my $status_text = $driver->find_element('#result-row .card-body')->get_text();
        last if ($status_text =~ $result_panel);
        if ($fail_on_incomplete && $status_text =~ qr/Result: incomplete/) {
            fail('test result is incomplete but shouldn\'t');
            return;
        }
        reload_manually($driver, $desc, $refresh_interval);
    }
    javascript_console_has_no_warnings_or_errors;
    reload_manually($driver, $desc);
    like($driver->find_element('#result-row .card-body')->get_text(), $result_panel, $desc);
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

    my $regex_closed = qr/Connection closed/;
    my $match_index;
    while (($match_index = match_regex_returning_index($message_regex, $log, $position_of_last_match)) < 0) {
        # check whether connection has been unexpectedly closed/opened
        if (   $message_regex ne $regex_closed
            && $diag_info ne 'paused'
            && $log =~ $regex_closed)
        {
            fail('web socket connection closed prematurely, was waiting for ' . $diag_info);
            return;
        }

        if ($diag_info eq 'paused') {
            # when waiting for paused, we will have to wait at least a minute for the first test module to pass
            # -> so let's try again only all 5 seconds here
            sleep 5;
            # -> print updated log so we see what's going on
            if ($log ne $previous_log) {
                print("developer console contains:\n$log\n");
            }
        }
        else {
            # try again in 1 second
            sleep 1;
        }
        wait_for_ajax;
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
    while (1) {
        my @scheduled_jobs = OpenQA::Scheduler::Scheduler::schedule();
        return if @scheduled_jobs;
        sleep 1;
    }
}

sub verify_one_job_displayed_as_scheduled {
    my ($driver) = @_;

    $driver->click_element_ok('All Tests', 'link_text');
    $driver->title_is('openQA: Test results', 'tests followed');
    wait_for_ajax;
    is(
        $driver->find_element_by_id('scheduled_jobs_heading')->get_text(),
        '1 scheduled jobs',
        'test displayed as scheduled',
    );
}

1;
