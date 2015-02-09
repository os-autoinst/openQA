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
    plan tests => 22;
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
is((shift @headers)->get_text(), "QEMUCPU", "3rd column");
is((shift @headers)->get_text(), "LAPTOP",  "4th column");
is((shift @headers)->get_text(), "other variables", "5th column");
is((shift @headers)->get_text(), "action",  "6th column");

# now check one row by example
$elem = $driver->find_element('.admintable tbody tr:nth-child(3)', 'css');
@headers = $driver->find_child_elements($elem, 'td');

# the headers are specific to our fixtures - if they change, we have to adapt
is((shift @headers)->get_text(), "Laptop_64",    "name");
is((shift @headers)->get_text(), "qemu", "backend");
is((shift @headers)->get_text(), "qemu64", "cpu");
is((shift @headers)->get_text(), "1",  "LAPTOP");

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

#print $driver->get_page_source();

#open(my $fh,'>','mojoResults.png');
#binmode($fh);
#my $png_base64 = $driver->screenshot();
#print($fh MIME::Base64::decode_base64($png_base64));
#close($fh);

#

t::ui::PhantomTest::kill_phantom();
done_testing();
