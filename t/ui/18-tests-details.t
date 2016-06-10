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

$driver->get($baseurl . "tests/99946");
is($driver->get_title(), 'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results', 'tests/99946 followed');

$driver->find_element('installer_timezone', 'link_text')->click();
is($driver->get_current_url(), $baseurl . "tests/99946/modules/installer_timezone/steps/1/src", "on src page for nstaller_timezone test");

is($driver->find_element('.cm-comment', 'css')->get_text(), '#!/usr/bin/perl -w', "we have a perl comment");

$driver->get($baseurl . "tests/99937");
$driver->find_element('[title="wait_serial"]', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;
ok($driver->find_element('#preview_container_out', 'css')->is_displayed(), "preview window opens on click");
like($driver->find_element('#preview_container_in', 'css')->get_text(), qr/wait_serial expected/, "Preview text with wait_serial output shown");
$driver->find_element('[title="wait_serial"]', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;
ok($driver->find_element('#preview_container_out', 'css')->is_hidden(), "preview window closed after clicking again");

#print $driver->get_page_source();
#t::ui::PhantomTest::make_screenshot('mojoResults.png');

t::ui::PhantomTest::kill_phantom();
done_testing();
