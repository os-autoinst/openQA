#! /usr/bin/perl

# Copyright (C) 2014-2017 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is($driver->get_title(), "openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");

my @texts = map { $_->get_text() } $driver->find_elements('.progress-bar-softfailed', 'css');
is_deeply(\@texts, ['2 softfailed'], 'Progress bars show soft fails');

is($driver->find_element_by_id('user-action')->get_text(), 'Logged in as Demo', "logged in as demo");

# follow a build to overview page
$driver->find_element_by_link_text('Build0048')->click();
is($driver->get_title(), "openQA: Test summary", "on overview page");

is($driver->find_element('.result_softfailed')->get_text(), '', 'We see one softfail');
# follow a build to the step page
$driver->find_element_by_link_text('logpackages')->click();
is($driver->get_title(), 'openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results', 'on test page');

# expect the failure to be displayed
is(
    $driver->find_element_by_id('step_view')->get_attribute('data-image'),
    '/tests/99938/images/logpackages-1.png',
    'Failure displayed'
);

# now navigate back
$driver->find_element('.navbar-brand')->click();
is($driver->get_title(), "openQA", "on main page");

$driver->get("/tests/99938#previous");

is($driver->find_element_by_id('scenario')->is_displayed(), 1, "Scenario header displayed");
like($driver->find_element_by_id('scenario')->get_text(), qr/Results for.*/, "Scenario header text");

$driver->find_element_by_link_text('Settings')->click();
like($driver->get_current_url(), qr(\Qtests/99938#settings\E$), "hash marks tab");

$driver->find_element_by_link_text('Details')->click();
like($driver->get_current_url(), qr(\Qtests/99938#\E$), "hash marks tab 2");

t::ui::PhantomTest::kill_phantom();
done_testing();
