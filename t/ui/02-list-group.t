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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

#
# List with no parameters
#
$driver->title_is("openQA", "on main page");
#
# Test the legacy redirection
#
is($driver->get("/tests"), 1, "/tests");

is($driver->get("/tests?groupid=0"), 1, "list jobs without group");

my @rows = $driver->find_child_elements($driver->find_element('#scheduled tbody'), "tr");
is(@rows, 1, 'one sheduled job without group');

ok($driver->get("/tests?groupid=1001"), "list jobs without group 1001");
@rows = $driver->find_child_elements($driver->find_element('#running tbody'), "tr");
is(@rows, 1, 'one running job with this group');
isnt($driver->find_element('#running #job_99963'), undef, '99963 listed');
#t::ui::PhantomTest::make_screenshot('mojoResults.png');


kill_phantom();
done_testing();
