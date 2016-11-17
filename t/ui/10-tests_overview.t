# Copyright (C) 2014 SUSE Linux Products GmbH
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

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = t::ui::PhantomTest::call_phantom();

unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

#
# Overview with incorrect parameters
#
$t->get_ok('/tests/overview')->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', distri => 'opensuse'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', version => '13.1'})->status_is(404);

#
# Overview of build 0091
#
my $get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', build => '0091'});
$get->status_is(200);

my $summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Overall Summary of opensuse 13\.1 build 0091/i);
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 2 Running: 2 None: 1/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_i586');
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists('#flavor_GNOME-Live_arch_i686');
$get->element_exists_not('#flavor_GNOME-Live_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_i586_kde .result_passed');
$get->element_exists('#res_GNOME-Live_i686_RAID0 i.state_cancelled');
$get->element_exists('#res_DVD_i586_RAID1 i.state_scheduled');
$get->element_exists_not('#res_DVD_x86_64_doc');

#
# Overview of build 0048
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'});
$get->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/\QPassed: 0 Soft Failure: 2 Failed: 1\E/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i586');
$get->element_exists_not('#flavor_GNOME-Live_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_x86_64_doc .result_failed');
$get->element_exists('#res_DVD_x86_64_kde .result_softfailed');
$get->element_exists_not('#res_DVD_i586_doc');
$get->element_exists_not('#res_DVD_i686_doc');

my $failedmodules
  = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#res_DVD_x86_64_doc .failedmodule a')->all_text);
like($failedmodules, qr/logpackages/i, "failed modules are listed");

#
# Default overview for 13.1
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'});
$get->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Summary of opensuse 13\.1 build 0091/i);
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 2 Running: 2 None: 1/i);

#
# Default overview for Factory
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory'});
$get->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Summary of opensuse Factory build 0048\@0815/i);
like($summary, qr/\QPassed: 0 Failed: 1\E/i);


#
# Still possible to check an old build
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '87.5011'});
$get->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Summary of opensuse Factory build 87.5011/);
like($summary, qr/Passed: 0 Incomplete: 1 Failed: 0/);

# Advanced query parameters can be forwarded
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', result => 'passed'})
  ->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Summary of opensuse 13\.1 build 0091/i, "Still references the last build");
like($summary, qr/Passed: 2 Failed: 0/i, "Only passed are shown");
$get->element_exists('#res_DVD_i586_kde .result_passed');
$get->element_exists('#res_DVD_i586_textmode .result_passed');
$get->element_exists_not('#res_DVD_i586_RAID0 .state_scheduled');
$get->element_exists_not('#res_DVD_x86_64_kde .state_running');
$get->element_exists_not('#res_GNOME-Live_i686_RAID0 .state_cancelled');
$get->element_exists_not('.result_failed');
$get->element_exists_not('.state_cancelled');

# This time show only failed
$get
  = $t->get_ok(
    '/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048', result => 'failed'})
  ->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Passed: 0 Failed: 1/i);
$get->element_exists('#res_DVD_x86_64_doc .result_failed');
$get->element_exists_not('#res_DVD_x86_64_kde .result_passed');

$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048', todo => 1})
  ->status_is(200);
$summary = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
like($summary, qr/Passed: 0 Soft Failure: 2 Failed: 1/i, 'todo=1 shows all unlabeled failed');


#
# Test filter form
#

# Test initial state of architecture text box
$get
  = $t->get_ok(
    '/tests/overview' => form => {distri => 'opensuse', version => 'Factory', result => 'passed', arch => 'i686'})
  ->status_is(200);
# FIXME: works when testing manually, but accessing the value via Mojo doesn't work
#is($t->tx->res->dom->at('#filter-arch')->val, 'i686', 'default state of architecture');

is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();

# Test initial state of checkboxes and applying changes
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=Factory&build=0048&todo=1&result=passed');
$driver->find_element('#filter-panel .panel-heading', 'css')->click();
$driver->find_element('#filter-todo',                 'css')->click();
$driver->find_element('#filter-passed',               'css')->click();
$driver->find_element('#filter-failed',               'css')->click();
$driver->find_element('#filter-form button',          'css')->click();
$driver->find_element('#res_DVD_x86_64_doc',          'css');
my @filtered_out = $driver->find_elements('#res_DVD_x86_64_kde', 'css');
is(scalar @filtered_out, 0, 'result filter correctly applied');

# Test whether all URL parameter are passed correctly
my $url_with_escaped_parameters
  = $baseurl . 'tests/overview?arch=&distri=opensuse&build=0091&version=Staging%3AI&groupid=1001';
$driver->get($url_with_escaped_parameters);
$driver->find_element('#filter-panel .panel-heading', 'css')->click();
$driver->find_element('#filter-form button',          'css')->click();
is($driver->get_current_url(), $url_with_escaped_parameters . '#', 'escaped URL parameters are passed correctly');

# Test failed module info async update
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001');
my $fmod = $driver->find_elements('.failedmodule', 'css')->[1];
$driver->mouse_move_to_location(element => $fmod, xoffset => 8, yoffset => 8);
t::ui::PhantomTest::wait_for_ajax;
like($driver->find_elements('.failedmodule a', 'css')->[1]->get_attribute('href'),
    qr/\/3$/, 'ajax update failed module step');

$t->get_ok('/tests/99937/modules/kate/fails')->json_is('/failed_needles' => ["test-kate-1"], 'correct failed needles');
$t->get_ok('/tests/99937/modules/zypper_up/fails')
  ->json_is('/first_failed_step' => 1, 'failed module: fallback to first step');

t::ui::PhantomTest::kill_phantom();

done_testing();
