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

# locations for dummy needle files
my $needle_dir       = 't/data/openqa/share/tests/opensuse/needles/';
my $needle_json_file = $needle_dir . 'inst-timezone-text.json';
my $needle_png_file  = $needle_dir . 'inst-timezone-text.png';

# ensure needle dir can be listed (might not be the case because previous test run failed)
chmod(0755, $needle_dir);

# create dummy files for needle
open(FNAME, '>', $needle_json_file);
print FNAME 'go away later';
close(FNAME);
open(FNAME, '>', $needle_png_file);
print FNAME 'go away later';
close(FNAME);

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is(-f $needle_json_file, 1, "file is created");

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

my @trs = $driver->find_elements('#needles tr', 'css');
# skip header
my @tds = $driver->find_child_elements($trs[1], 'td', 'css');
is((shift @tds)->get_text(), 'fixtures', "Path is fixtures");
is((shift @tds)->get_text(), 'inst-timezone-text.json', "Name is right");
# does not really make sense, but fixtures are fake
is((shift @tds)->get_text(), 'a day ago',          "last use is right");
is((shift @tds)->get_text(), 'about 14 hours ago', "last match is right");

$driver->find_element('a day ago', 'link_text')->click();
like(
    $driver->execute_script("return window.location.href"),
    qr(\Q/tests/99937#step/partitioning_finish/1\E),
    "redirected to right module"
);

# go back to needles
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Needles',        'link_text')->click();
t::ui::PhantomTest::wait_for_ajax;

$driver->find_element('about 14 hours ago', 'link_text')->click();
like(
    $driver->execute_script("return window.location.href"),
    qr(\Q/tests/99937#step/partitioning/1\E),
    "redirected to right module too"
);

# go back to needles
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Needles',        'link_text')->click();
t::ui::PhantomTest::wait_for_ajax;

subtest 'delete needle' => sub {
    # disable animations to speed up test
    $driver->execute_script('$(\'#confirm_delete\').removeClass(\'fade\');');

    # select all needles and open modal dialog for deletion
    $driver->find_element('td input', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;
    $driver->find_element('#delete_all', 'css')->click();

    is($driver->find_element('#confirm_delete', 'css')->is_displayed(), 1, 'modal dialog');
    is($driver->find_element('#confirm_delete .modal-title', 'css')->get_text(), 'Needle deletion', 'title matches');
    is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 1, 'one needle outstanding for deletion');
    is(scalar @{$driver->find_elements('#failed-needles li',      'css')}, 0, 'no failed needles so far');
    is($driver->find_element('#outstanding-needles li', 'css')->get_text(),
        'inst-timezone-text.json', 'right needle name displayed');

    subtest 'error case' => sub {
        chmod(0444, $needle_dir);
        $driver->find_element('#really_delete', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 0, 'no outstanding needles');
        is(scalar @{$driver->find_elements('#failed-needles li',      'css')}, 1, 'but failed needle');
        is(
            $driver->find_element('#failed-needles li', 'css')->get_text(),
"inst-timezone-text.json\nUnable to delete t/data/openqa/share/tests/opensuse/needles/inst-timezone-text.json and t/data/openqa/share/tests/opensuse/needles/inst-timezone-text.png",
            'right needle name and error message displayed'
        );
        $driver->find_element('#close_delete', 'css')->click();
    };

    # select all needles again and re-open modal dialog for deletion
    t::ui::PhantomTest::wait_for_ajax;    # required due to server-side datatable
    $driver->find_element('td input',    'css')->click();
    $driver->find_element('#delete_all', 'css')->click();
    is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')},
        1, 'still one needle outstanding for deletion');
    is(scalar @{$driver->find_elements('#failed-needles li', 'css')},
        0, 'failed needles from last time shouldn\'t appear again when reopening deletion dialog');
    is($driver->find_element('#outstanding-needles li', 'css')->get_text(),
        'inst-timezone-text.json', 'still right needle name displayed');

    subtest 'successful deletion' => sub {
        chmod(0755, $needle_dir);
        $driver->find_element('#really_delete', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 0, 'no outstanding needles');
        is(scalar @{$driver->find_elements('#failed-needles li',      'css')}, 0, 'no failed needles');
        $driver->find_element('#close_delete', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;    # required due to server-side datatable
        is(-f $needle_json_file, undef, 'JSON file is gone');
        is(-f $needle_png_file,  undef, 'png file is gone');
        is(
            $driver->find_element('#needles tbody tr', 'css')->get_text(),
            'No data available in table',
            'no needles left'
        );
    };
};

t::ui::PhantomTest::kill_phantom();
done_testing();
