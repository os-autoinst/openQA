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

use Module::Load::Conditional qw(can_load);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Log 'log_debug';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $driver = call_driver();
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# DO NOT MOVE THIS INTO A 'use' FUNCTION CALL! It will cause the tests
# to crash if the module is unavailable
unless (can_load(modules => {'Selenium::Remote::WDKeys' => undef,})) {
    plan skip_all => 'Install Selenium::Remote::WDKeys to run this test';
    exit(0);
}

#
# List with no parameters
#
$driver->title_is("openQA", "on main page");
my @build_headings = $driver->find_elements('.h4', 'css');
is(scalar @build_headings, 4, '4 builds shown');

# click on last build which should be Build0091
$driver->find_child_element($build_headings[-1], 'a', 'css')->click();
like(
    $driver->find_element_by_id('summary')->get_text(),
    qr/Overall Summary of opensuse test build 0091/,
    'we are on build 91'
);

is($driver->get('/?limit_builds=1'), 1, 'index page accepts limit_builds parameter');
wait_for_ajax;
is(scalar @{$driver->find_elements('.h4', 'css')},             2, 'only one build per group shown');
is($driver->get('/?time_limit_days=0.02&limit_builds=100000'), 1, 'index page accepts time_limit_days parameter');
wait_for_ajax;
is(scalar @{$driver->find_elements('.h4', 'css')},             0, 'no builds shown');
is($driver->get('/?time_limit_days=0.05&limit_builds=100000'), 1, 'index page accepts time_limit_days parameter');
wait_for_ajax;
is(scalar @{$driver->find_elements('.h4', 'css')}, 2, 'only the one hour old builds is shown');

# group overview
$driver->find_element_by_link_text('opensuse')->click();
my $build_url = $driver->get_current_url();
$build_url =~ s/\?.*//;
log_debug('build_url: ' . $build_url);
is(scalar @{$driver->find_elements('.h4', 'css')}, 5, 'number of builds for opensuse');
is(
    $driver->find_element_by_id('group_description')->get_text(),
    "Test description\nwith bugref bsc#1234",
    'description shown'
);
is(
    $driver->find_element('#group_description a')->get_attribute('href'),
    'https://bugzilla.suse.com/show_bug.cgi?id=1234',
    'bugref in description rendered as link'
);
$driver->get('/group_overview/1002');
is(scalar @{$driver->find_elements('#group_description', 'css')},
    0, 'no well for group description shown if none present');
is($driver->get($build_url . '?limit_builds=2'), 1, 'group overview page accepts query parameter, too');
$driver->get($build_url . '?limit_builds=0');
is(scalar @{$driver->find_elements('div.build-row .h4', 'css')}, 0, 'all builds filtered out');
is(
    $driver->find_element('h2')->get_text(),
    'Last Builds for opensuse',
    'group name shown correctly when all builds filtered out'
);

$driver->find_element_by_link_text('400')->click();
is($driver->find_element('#more_builds b')->get_text(), 400, 'limited to the selected number');
$driver->find_element_by_link_text('tagged')->click();
is(scalar @{$driver->find_elements('.h4', 'css')}, 0, 'no tagged builds exist');

$driver->get('/group_overview/1001');
my $res = OpenQA::Test::Case::trim_whitespace($driver->find_element_by_id('more_builds')->get_text);
is($res, q{Limit to 10 / 20 / 50 / 100 / 400 builds, only tagged / all}, 'more builds can be requested');

is($driver->get('/?group=opensuse'), 1, 'group parameter is not exact by default');
wait_for_ajax;
is(scalar @{$driver->find_elements('h2', 'css')}, 2, 'both job groups shown');
is($driver->get('/?group=test'),                  1, 'group parameter filters as expected');
wait_for_ajax;
is(scalar @{$driver->find_elements('h2', 'css')},                 1, 'only one job group shown');
is($driver->find_element_by_link_text('opensuse test')->get_text, 'opensuse test');
is($driver->get('/?group=opensuse$'), 1, 'group parameter can be used for exact matching, though');
wait_for_ajax;
is(scalar @{$driver->find_elements('h2', 'css')},            1, 'only one job group shown');
is($driver->find_element_by_link_text('opensuse')->get_text, 'opensuse');
is($driver->get('/?group=opensuse$&group=test'), 1, 'multiple group parameter can be used to ease building queries');
wait_for_ajax;
is(scalar @{$driver->find_elements('h2', 'css')}, 2, 'both job groups shown');
$driver->get('/?group=');
wait_for_ajax;
is(scalar @{$driver->find_elements('h2', 'css')}, 2, 'a single, empty group parameter has no affect');

subtest 'filter form' => sub {
    $driver->get('/');
    like($driver->find_element('#filter-panel .help_popover')->get_attribute('data-title'),
        qr/Help/, 'help popover is shown');
    wait_for_ajax_and_animations;
    my $url = $driver->get_current_url;
    $driver->find_element('#filter-panel .card-header')->click();
    $driver->find_element_by_id('filter-group')->send_keys('SLE 12 SP2');
    my $ele = $driver->find_element_by_id('filter-limit-builds');
    $ele->click();
    $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{end}, '8');    # appended to default '3'
    $ele = $driver->find_element_by_id('filter-time-limit-days');
    $ele->click();
    $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{end}, '2');    # appended to default '14'
    $driver->find_element('#filter-apply-button')->click();
    wait_for_ajax;
    $url .= '?group=SLE%2012%20SP2&limit_builds=38&time_limit_days=142&interval=';
    is($driver->get_current_url, $url, 'URL parameters for filter are correct');
};

# JSON representation of index page
$driver->get('/dashboard_build_results.json');
like($driver->get_page_source(), qr("key":"Factory-0048"), 'page rendered as JSON');

# parent group overview: tested in t/22-dashboard.t

kill_driver();
done_testing();
