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
use Time::HiRes qw(sleep);

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $fname = "t/data/openqa/share/tests/opensuse/needles/inst-timezone-text.json";
open(FNAME, '>', $fname);
print FNAME "go away later";
close(FNAME);

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is(-f $fname, 1, "file is created");

is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");

is($driver->find_element('#user-action', 'css')->get_text(), 'Logged in as Demo', "logged in as demo");

# Demo is admin, so go there
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Needles',        'link_text')->click();
t::ui::PhantomTest::wait_for_ajax;

my @trs = $driver->find_elements('tr', 'css');
# skip header
my @tds = $driver->find_child_elements($trs[1], 'td', 'css');
is((shift @tds)->get_text(), 'fixtures', "Path is fixtures");
is((shift @tds)->get_text(), 'inst-timezone-text.json', "Name is right");
# does not really make sense, but fixtures are fake
is((shift @tds)->get_text(), 'a day ago',          "last use is right");
is((shift @tds)->get_text(), 'about 14 hours ago', "last match is right");

$driver->find_element('a day ago', 'link_text')->click();
like($driver->execute_script("return window.location.href"), qr(\Q/tests/99937#step/partitioning_finish/1\E), "redirected to right module");

# go back to needles
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Needles',        'link_text')->click();
t::ui::PhantomTest::wait_for_ajax;

$driver->find_element('about 14 hours ago', 'link_text')->click();
like($driver->execute_script("return window.location.href"), qr(\Q/tests/99937#step/partitioning/1\E), "redirected to right module too");

# go back to needles
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Needles',        'link_text')->click();
t::ui::PhantomTest::wait_for_ajax;

$driver->find_element('td input', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;
$driver->find_element('#delete_all', 'css')->click();
# wait for the javascript to be done
while (!$driver->find_element('#confirm_delete', 'css')->is_displayed()) {
    sleep .1;
}
is($driver->find_element('#confirm_delete',              'css')->is_displayed(), 1,                                  'modal dialog');
is($driver->find_element('#confirm_delete .modal-title', 'css')->get_text(),     'Really delete following needles?', 'title matches');
is($driver->find_element('#confirm_delete .modal-body',  'css')->get_text(),     'inst-timezone-text.json',          'Right needle name displayed');

$driver->find_element('#really_delete', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;

is(-f $fname, undef, "file is gone");

t::ui::PhantomTest::kill_phantom();
done_testing();
