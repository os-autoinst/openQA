#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '50';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl');

use OpenQA::SeleniumTest;

my $driver = call_driver();
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

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
