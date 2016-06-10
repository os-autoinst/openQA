# Copyright (C) 2014-2016 SUSE LLC
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
my $baseurl = $driver->get_current_url();
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");

like($driver->find_element('#user-info', 'css')->get_text(), qr/Logged in as Demo.*Logout/, "logged in as demo");

# follow a build to overview page
$driver->find_element('Build0048', 'link_text')->click();
is($driver->get_title(), "openQA: Test summary", "on overview page");

# follow a build to the step page
$driver->find_element('logpackages', 'link_text')->click();
is($driver->get_title(), 'openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results', 'on test page');

# expect the failure to be displayed
is($driver->find_element('#step_view', 'css')->get_attribute('data-image'), '/tests/99938/images/logpackages-1.png', 'Failure displayed');

# now navigate back
$driver->find_element('openQA', 'link_text')->click();
is($driver->get_title(), "openQA", "on main page");

t::ui::PhantomTest::kill_phantom();
done_testing();
