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

is(scalar @{$driver->find_elements('h4', 'css')}, 4);

$driver->find_element('Build0091', 'link_text')->click();

like($driver->find_element('#summary', 'css')->get_text(), qr/Overall Summary of opensuse build 0091/, 'we are on build 91');

is($driver->get($baseurl . '?time_limit_days=1&limit_builds=1'), 1, 'index page accepts query parameters');
is(scalar @{$driver->find_elements('h4', 'css')}, 2, 'only one build per group shown');

$driver->find_element('opensuse', 'link_text')->click();

is(scalar @{$driver->find_elements('h4', 'css')}, 4, 'default number of builds shown');
is($driver->get($baseurl . '?limit_builds=2'), 1, 'group overview page accepts query parameter, too');

#t::ui::PhantomTest::make_screenshot('mojoResults.png');

t::ui::PhantomTest::kill_phantom();
done_testing();
