#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 05-job_modules.pl');

use OpenQA::SeleniumTest;

driver_missing unless my $driver = call_driver;

$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");

my @texts = map { $_->get_text() } wait_for_element(selector => '.progress-bar-softfailed');
is_deeply(\@texts, ['2 softfailed'], 'Progress bars show soft fails');

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

# follow a build to overview page
$driver->find_element_by_link_text('Build0048')->click();
$driver->title_is("openQA: Test summary", "on overview page");

is($driver->find_element('.result_softfailed')->get_text(), '', 'We see one softfail');
# follow a build to the step page
$driver->find_element_by_link_text('logpackages')->click();
$driver->title_is('openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results', 'on test page');

# expect the failure to be displayed
is(
    wait_for_element(selector => '#step_view')->get_attribute('data-image'),
    '/tests/99938/images/logpackages-1.png',
    'Failure displayed'
);

# now navigate back
$driver->find_element('.navbar-brand')->click();
$driver->title_is("openQA", "on main page");

$driver->get("/tests/99938#next_previous");

is($driver->find_element_by_id('scenario')->is_displayed(), 1, "Scenario header displayed");
like($driver->find_element_by_id('scenario')->get_text(), qr/Next & previous results for.*/, "Scenario header text");

$driver->find_element_by_link_text('Settings')->click();
like($driver->get_current_url(), qr(\Qtests/99938#settings\E$), "hash marks tab");

$driver->find_element_by_link_text('Details')->click();
like($driver->get_current_url(), qr(\Qtests/99938#\E$), "hash marks tab 2");

kill_driver();
done_testing();
