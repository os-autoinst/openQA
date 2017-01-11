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
use Test::Warnings;
use OpenQA::Test::Case;
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $driver = t::ui::PhantomTest::call_phantom();

unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();

# Test initial state of checkboxes and applying changes
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=Factory&build=0048&todo=1&result=passed');
$driver->find_element('#filter-panel .panel-heading')->click();
$driver->find_element_by_id('filter-todo')->click();
$driver->find_element_by_id('filter-passed')->click();
$driver->find_element_by_id('filter-failed')->click();
$driver->find_element('#filter-form button')->click();
$driver->find_element_by_id('res_DVD_x86_64_doc');
my @filtered_out = $driver->find_elements('#res_DVD_x86_64_kde', 'css');
is(scalar @filtered_out, 0, 'result filter correctly applied');

# Test whether all URL parameter are passed correctly
my $url_with_escaped_parameters
  = $baseurl . 'tests/overview?arch=&distri=opensuse&build=0091&version=Staging%3AI&groupid=1001';
$driver->get($url_with_escaped_parameters);
$driver->find_element('#filter-panel .panel-heading')->click();
$driver->find_element('#filter-form button')->click();
is($driver->get_current_url(), $url_with_escaped_parameters . '#', 'escaped URL parameters are passed correctly');

# Test failed module info async update
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001');
my $fmod = $driver->find_elements('.failedmodule', 'css')->[1];
$driver->mouse_move_to_location(element => $fmod, xoffset => 8, yoffset => 8);
t::ui::PhantomTest::wait_for_ajax;
like($driver->find_elements('.failedmodule a', 'css')->[1]->get_attribute('href'),
    qr/\/3$/, 'ajax update failed module step');

my @descriptions = $driver->find_elements('td.name a', 'css');
is(scalar @descriptions, 1, 'only test suites with description content are shown as links');
$descriptions[0]->click();
is($driver->find_element('.popover-title')->get_text, 'kde', 'description popover shows content');

t::ui::PhantomTest::kill_phantom();

done_testing();
