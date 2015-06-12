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

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA');

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 5;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

#
# List with no parameters
#

is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");

$driver->find_element('opensuse', 'link_text')->click();

is($driver->find_element('h1:first-of-type', 'css')->get_text(), 'Last Builds for Group opensuse', "on group overview");

$driver->find_element('textarea',       'css')->send_keys('This is a cool test');
$driver->find_element('#submitComment', 'css')->click();

is($driver->find_element('h4.media-heading', 'css')->get_text(), "Demo wrote less than a minute ago", "heading");

#t::ui::PhantomTest::make_screenshot('mojoResults.png');
#print $driver->get_page_source();

is($driver->find_element('div.media-comment', 'css')->get_text(), "This is a cool test", "body");

t::ui::PhantomTest::kill_phantom();

done_testing();
