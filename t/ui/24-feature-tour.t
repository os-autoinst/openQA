#! /usr/bin/perl

# Copyright (C) 2015-2017 SUSE LLC
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
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = call_phantom();

unless ($driver) {
    plan skip_all => $t::ui::PhantomTest::phantommissing;
    exit(0);
}


$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();

# we are back on the main page
# make sure tour does not appear for demo user
$driver->title_is("openQA", "back on main page");
$driver->find_element_by_link_text('Logged in as Demo')->click();
$driver->find_element_by_link_text('Logout')->click();

# quit tour temporarly
$driver->get('/login?user=nobody');
ok($driver->find_element('#step-0')->is_displayed(), 'tour popover is displayed');
my $text = $driver->find_element('h3.popover-title')->get_text();
is($text,'Interested in new features?');
$driver->find_element_by_id('end')->click();
$driver->find_element_by_link_text('Logged in as nobody')->click();
$driver->find_element_by_link_text('Logout')->click();

# check if tour appears again after clearing cache
my $clear = q{
    localStorage.removeItem('tour_end');
};
$driver->execute_script($clear);
$driver->refresh();
$driver->get('/login?user=nobody');
ok($driver->find_element('#step-0')->is_displayed(), 'tour popover is displayed again');

# do the tour
$driver->find_element_by_id('next')->click();
$driver->find_element_by_id('next')->click();
ok($driver->find_element('#step-2')->is_displayed(), 'tour popover is displayed');
$driver->pause();
$driver->find_element_by_id('prev')->click();
$driver->find_element_by_id('end')->click();
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

kill_phantom();

done_testing();
