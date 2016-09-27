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

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

#
# List with no parameters
#
is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();

is(scalar @{$driver->find_elements('h4', 'css')}, 4, '4 builds shown');

$driver->find_element('Build0091', 'link_text')->click();
like($driver->find_element('#summary', 'css')->get_text(), qr/Overall Summary of opensuse test build 0091/, 'we are on build 91');

is($driver->get($baseurl . '?limit_builds=1'), 1, 'index page accepts limit_builds parameter');
is(scalar @{$driver->find_elements('h4', 'css')}, 2, 'only one build per group shown');
is($driver->get($baseurl . '?time_limit_days=0.02&limit_builds=100000'), 1, 'index page accepts time_limit_days parameter');
is(scalar @{$driver->find_elements('h4', 'css')}, 0, 'no builds shown');
is($driver->get($baseurl . '?time_limit_days=0.05&limit_builds=100000'), 1, 'index page accepts time_limit_days parameter');
is(scalar @{$driver->find_elements('h4', 'css')}, 2, 'only the one hour old builds is shown');

$driver->find_element('opensuse', 'link_text')->click();

is(scalar @{$driver->find_elements('h4', 'css')}, 5, 'number of builds for opensuse');
is($driver->get($driver->get_current_url() . '?limit_builds=2'), 1, 'group overview page accepts query parameter, too');

my $more_builds = $t->get_ok($baseurl . 'group_overview/1001')->tx->res->dom->at('#more_builds');
my $res         = OpenQA::Test::Case::trim_whitespace($more_builds->all_text);
is($res, q{Limit to 10 / 20 / 50 / 100 / 400 builds, only tagged / all}, 'more builds can be requested');
$driver->find_element('400', 'link_text')->click();
is($driver->find_element('#more_builds b', 'css')->get_text(), 400, 'limited to the selected number');
$driver->find_element('tagged', 'link_text')->click();
is(scalar @{$driver->find_elements('h4', 'css')}, 0, 'no tagged builds exist');

is($driver->get($baseurl . '?group=opensuse'), 1, 'group parameter is not exact by default');
is(scalar @{$driver->find_elements('h2', 'css')}, 2, 'both job groups shown');
is($driver->get($baseurl . '?group=test'), 1, 'group parameter filters as expected');
is(scalar @{$driver->find_elements('h2', 'css')}, 1, 'only one job group shown');
is($driver->find_element('opensuse test', 'link_text')->get_text, 'opensuse test');
is($driver->get($baseurl . '?group=opensuse$'), 1, 'group parameter can be used for exact matching, though');
is(scalar @{$driver->find_elements('h2', 'css')}, 1, 'only one job group shown');
is($driver->find_element('opensuse', 'link_text')->get_text, 'opensuse');
is($driver->get($baseurl . '?group=opensuse$&group=test'), 1, 'multiple group parameter can be use to ease building queries');
is(scalar @{$driver->find_elements('h2', 'css')}, 2, 'both job groups shown');

subtest 'filter form' => sub {
    $driver->get($baseurl);
    $driver->find_element('#filter-panel .panel-heading', 'css')->click();
    $driver->find_element('#filter-group',                'css')->send_keys('SLE 12 SP2');
    $driver->find_element('#filter-limit-builds',         'css')->send_keys('8');            # appended to default '3'
    $driver->find_element('#filter-time-limit-days',      'css')->send_keys('2');            # appended to default '14'
    $driver->find_element('#filter-form button',          'css')->click();
    is($driver->get_current_url(), $baseurl . '?group=SLE+12+SP2&limit_builds=38&time_limit_days=142#', 'URL parameters for filter are correct');
};

t::ui::PhantomTest::kill_phantom();
done_testing();
