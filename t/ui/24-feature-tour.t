#!/usr/bin/env perl
# Copyright (C) 2015-2020 SUSE LLC
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
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '12';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case   = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema      = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '03-users.pl');
my $t           = Test::Mojo->new('OpenQA::WebAPI');
$schema->resultset('Users')->create({username => 'nobody', feature_version => 1});

plan skip_all => $OpenQA::SeleniumTest::drivermissing unless my $driver = call_driver;

$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();

# we are back on the main page
# make sure tour does not appear for demo user
$driver->title_is("openQA", "back on main page");
is(scalar(@{$driver->find_elements('#step-0')}), 0);
$driver->find_element_by_link_text('Logged in as Demo')->click();
$driver->find_element_by_link_text('Logout')->click();

# quit tour temporarly
$driver->get('/login?user=nobody');
wait_for_element(selector => '#step-0', is_displayed => 1, description => 'tour popover is displayed');
my $text = $driver->find_element('h3.popover-header')->get_text();
is($text, 'All tests area');
$driver->find_element_by_link_text('Logged in as nobody')->click();
$driver->find_element_by_link_text('Logout')->click();

# check if tour appears again after clearing cache
my $clear = q{
    localStorage.removeItem('tour_end');
};
$driver->execute_script($clear);
$driver->refresh();
$driver->get('/login?user=nobody');
wait_for_element(selector => '#step-0', is_displayed => 1, description => 'tour popover is displayed again');

# do the tour
$driver->find_element_by_id('next')->click();
wait_for_element(selector => '#step-1', is_displayed => 1, description => 'tour popover is displayed');
$driver->pause();
$driver->find_element_by_id('prev')->click();
$driver->execute_script($clear);
$driver->refresh();

# check if the 'dont notify me anymore' part works
$driver->find_element_by_id('dont-notify')->click();
$driver->find_element_by_id('confirm')->click();
$driver->find_element_by_link_text('Logged in as nobody')->click();
$driver->find_element_by_link_text('Logout')->click();

# make sure tour does not appear again after logging back in
$driver->execute_script($clear);
$driver->refresh();
$driver->get('/login?user=nobody');
is(scalar(@{$driver->find_elements('#step-0')}), 0);

$driver->find_element_by_link_text('Logged in as nobody')->click();
$driver->find_element_by_link_text('Logout')->click();
$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
$driver->find_element_by_link_text('Logged in as Demo')->click();
$driver->find_element_by_link_text('Logout')->click();

kill_driver();

done_testing();
