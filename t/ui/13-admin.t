# Copyright (C) 2015 SUSE Linux GmbH
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
use OpenQA::Test::Case;
use Data::Dumper;
use IO::Socket::INET;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw/make_path remove_tree/;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 79;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

is($driver->get_title(), "openQA", "on main page");
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");
# but ...

like($driver->find_element('#user-info', 'css')->get_text(), qr/Logged as Demo.*Logout/, "logged in as demo");

# Demo is admin, so go there
$driver->find_element('admin', 'link_text')->click();

is($driver->get_title(), "openQA: Users", "on user overview");

sub add_job_group() {
    $driver->find_element('Job groups', 'link_text')->click();

    is($driver->get_title(), "openQA: Job groups", "on groups");

    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }

    like($driver->find_element('#groups_wrapper', 'css')->get_text(), qr/Showing 1 to 2 of 2 entries/, 'two groups in fixtures');
    $driver->find_element('#name', 'css')->send_keys('Cool Group');
    $driver->find_element('#submit', 'css')->click();
    like($driver->find_element('#groups_wrapper', 'css')->get_text(), qr/Showing 1 to 3 of 3 entries/, 'group created');
    is($driver->find_element('#group_1003', 'css')->get_text(), 'Cool Group', 'group created');
    is($driver->find_element('.ui-state-highlight', 'css')->get_text(), 'Group Cool Group created', 'flash shown');
    #t::ui::PhantomTest::make_screenshot('mojoResults.png');
}

sub add_machine() {
    # go to machines first
    $driver->find_element('Machines', 'link_text')->click();

    is($driver->get_title(), "openQA: Machines", "on machines list");

    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }

    my $elem = $driver->find_element('.admintable thead tr', 'css');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(6, @headers, "6 columns");

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "name",    "1st column");
    is((shift @headers)->get_text(), "backend", "2nd column");
    is((shift @headers)->get_text(), "QEMUCPU",  "3rd column");
    is((shift @headers)->get_text(), "LAPTOP", "4th column");
    is((shift @headers)->get_text(), "other variables", "5th column");
    is((shift @headers)->get_text(), "action",  "6th column");

    # now check one row by example
    $elem = $driver->find_element('.admintable tbody tr:nth-child(3)', 'css');
    @headers = $driver->find_child_elements($elem, 'td');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "Laptop_64",    "name");
    is((shift @headers)->get_text(), "qemu", "backend");
    is((shift @headers)->get_text(), "qemu64",  "cpu");
    is((shift @headers)->get_text(), "1", "LAPTOP");

    is(@{$driver->find_elements('//button[@title="Edit"]')}, 3, "3 edit buttons before");

    is($driver->find_element('//input[@value="New machine"]')->click(), 1, 'new machine' );

    $elem = $driver->find_element('.admintable tbody tr:last-child', 'css');
    is($elem->get_text(), '=', "new row empty");
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]');
    is(6, @fields, "6 fields"); # one column has 2 fields
    (shift @fields)->send_keys('HURRA'); # name
    (shift @fields)->send_keys('ipmi'); # backend
    (shift @fields)->send_keys('kvm32'); # cpu

    is($driver->find_element('//button[@title="Add"]')->click(), 1, 'added' );
    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is(@{$driver->find_elements('//button[@title="Edit"]')}, 4, "4 edit buttons afterwards");
}

sub add_test_suite() {
    # go to tests first
    $driver->find_element('Test suites', 'link_text')->click();

    is($driver->get_title(), "openQA: Test suites", "on test suites");

    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }

    my $elem = $driver->find_element('.admintable thead tr', 'css');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(6, @headers, "6 columns");

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "name",    "1st column");
    is((shift @headers)->get_text(), "DESKTOP",  "2nd column");
    is((shift @headers)->get_text(), "PARALLEL_WITH", "3rd column");
    is((shift @headers)->get_text(), "INSTALLONLY", "4th column");
    is((shift @headers)->get_text(), "other variables",  "5th column");

    # now check one row by example
    $elem = $driver->find_element('.admintable tbody tr:nth-child(3)', 'css');
    @headers = $driver->find_child_elements($elem, 'td');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "RAID0",    "name");
    is((shift @headers)->get_text(), "kde",  "DESKTOP");
    is((shift @headers)->get_text(), "",  "PARALLEL_WITH");
    is((shift @headers)->get_text(), "1",  "INSTALLONLY");

    is(@{$driver->find_elements('//button[@title="Edit"]')}, 7, "7 edit buttons before");

    is($driver->find_element('//input[@value="New test suite"]')->click(), 1, 'new test suite' );

    $elem = $driver->find_element('.admintable tbody tr:last-child', 'css');
    is($elem->get_text(), '=', "new row empty");
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]');
    is(6, @fields, "6 fields"); # one column has 2 fields
    (shift @fields)->send_keys('xfce'); # name
    (shift @fields)->send_keys('xfce'); # desktop
    (shift @fields)->send_keys(''); # parallelwith
    (shift @fields)->send_keys(''); # installonly

    is($driver->find_element('//button[@title="Add"]')->click(), 1, 'added' );
    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is(@{$driver->find_elements('//button[@title="Edit"]')}, 8, "8 edit buttons afterwards");
}
#

sub add_product() {
    #print $driver->get_page_source();

    # go to product first
    $driver->find_element('Medium types', 'link_text')->click();

    is($driver->get_title(), "openQA: Medium types", "on products");

    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }

    my $elem = $driver->find_element('.admintable thead tr', 'css');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(8, @headers, "8 columns");

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "distri",    "1st column");
    is((shift @headers)->get_text(), "version", "2nd column");
    is((shift @headers)->get_text(), "flavor", "3rd column");
    is((shift @headers)->get_text(), "arch",  "4th column");
    is((shift @headers)->get_text(), "DVD", "5th column");
    is((shift @headers)->get_text(), "ISO_MAXSIZE",  "6th column");
    is((shift @headers)->get_text(), "other variables",  "7th column");

    # now check one row by example
    $elem = $driver->find_element('.admintable tbody tr:nth-child(1)', 'css');
    @headers = $driver->find_child_elements($elem, 'td');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "opensuse",    "distri");
    is((shift @headers)->get_text(), "13.1", "version");
    is((shift @headers)->get_text(), "DVD", "flavor");
    is((shift @headers)->get_text(), "i586", "arch");
    is((shift @headers)->get_text(), "1",  "DVD");
    is((shift @headers)->get_text(), "4700372992",  "MAX SIZE");

    is(@{$driver->find_elements('//button[@title="Edit"]')}, 1, "1 edit button before");

    is($driver->find_element('//input[@value="New medium"]')->click(), 1, 'new medium' );

    $elem = $driver->find_element('.admintable tbody tr:last-child', 'css');
    is($elem->get_text(), '=', "new row empty");
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]');
    is(8, @fields, "8 fields"); # one column has 2 fields
    (shift @fields)->send_keys('sle'); # distri
    (shift @fields)->send_keys('13'); # version
    (shift @fields)->send_keys('DVD'); # flavor
    (shift @fields)->send_keys('arm19'); # arch

    is($driver->find_element('//button[@title="Add"]')->click(), 1, 'added' );
    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is(@{$driver->find_elements('//button[@title="Edit"]')}, 2, "2 edit buttons afterwards");

    # check the distri name will be lowercase after added a new one
    is($driver->find_element('//input[@value="New medium"]')->click(), 1, 'new medium' );

    $elem = $driver->find_element('.admintable tbody tr:last-child', 'css');
    is($elem->get_text(), '=', "new row empty");
    @fields = $driver->find_child_elements($elem, '//input[@type="text"]');
    is(8, @fields, "8 fields"); # one column has 2 fields
    (shift @fields)->send_keys('OpeNSusE'); # distri name has capital letter and many upper/lower case combined
    (shift @fields)->send_keys('13.2'); # version
    (shift @fields)->send_keys('DVD'); # flavor
    (shift @fields)->send_keys('ppc64le'); # arch

    is($driver->find_element('//button[@title="Add"]')->click(), 1, 'added' );
    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is(@{$driver->find_elements('//button[@title="Edit"]')}, 3, "3 edit buttons afterwards");

}

add_product();
add_machine();
add_test_suite();

add_job_group();

is($driver->get_title(), "openQA: Job groups", "on job groups");

$driver->find_element('Cool Group', 'link')->click();

while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}

$driver->find_element('Test new medium as part of this group', 'link')->click();


# include the WDKeys module
use Selenium::Remote::WDKeys;

my $select = $driver->find_element('#medium', 'css');
my $option = $driver->find_child_element($select, './option[contains(text(), "sle-13-DVD-arm19")]');
$option->click();
$select = $driver->find_element('#machine', 'css');
$option = $driver->find_child_element($select, './option[contains(text(), "HURRA")]');
$option->click();
$select = $driver->find_element('#test', 'css');
$option = $driver->find_child_element($select, './option[contains(text(), "xfce")]');
$option->click();

$driver->find_element('//input[@type="submit"]')->submit();

is($driver->get_title(), "openQA: Jobs for Cool Group", "on job groups");

#print $driver->get_page_source();
my $td = $driver->find_element('#sle_13_DVD_arm19_xfce_chosen .search-field', 'css');
is('', $td->get_text(), 'field is empty for product 2');
$driver->mouse_move_to_location(element => $td);
$driver->button_down();
sleep 1;

$driver->send_keys_to_active_element('64bit');
$driver->send_keys_to_active_element(KEYS->{'enter'});

# now reload the page to see if we succeeded
$driver->find_element('Job groups', 'link_text')->click();

is($driver->get_title(), "openQA: Job groups", "on groups");
$driver->find_element('Cool Group', 'link')->click();

my @picks = $driver->find_elements('.search-choice', 'css');
is((shift @picks)->get_text(), '64bit', 'found one');
is((shift @picks)->get_text(), 'HURRA', 'found two');
is_deeply(\@picks, [], 'found no three');

#print $driver->get_page_source();
#t::ui::PhantomTest::make_screenshot('mojoResults.png');

# briefly check the asset list
$driver->find_element('Assets', 'link_text')->click();
is($driver->get_title(), "openQA: Assets", "on asset");

while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}


#t::ui::PhantomTest::make_screenshot('mojoResults.png');
#print $driver->get_page_source();

$td = $driver->find_element('tr#asset_1 td.t_created', 'css');
is('about 2 hours ago', $td->get_text(), 'timeago 2h');

t::ui::PhantomTest::kill_phantom();
done_testing();
