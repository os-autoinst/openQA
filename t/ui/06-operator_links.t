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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Test::Database;
use Data::Dumper;
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

my $t = Test::Mojo->new('OpenQA::WebAPI');

# we don't want to test javascript here, so we just test the javascript code
# List with no login
my $get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = false;/, "test list rendered without is_operator");

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = true;/, "test list rendered with is_operator");

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = false;/, "test list rendered without is_operator");

# now the same for scheduled jobs
$t->delete_ok('/logout')->status_is(302);

# List with no login
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#scheduled #job_99928 a.cancel');

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists('#scheduled #job_99928 a.cancel');

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#scheduled #job_99928 a.cancel');

# operator has access to part of admin menu - using phantomjs
is($driver->get_title(), "openQA", "on main page");
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");
# but ...

like($driver->find_element('#user-info', 'css')->get_text(), qr/Logged in as Demo.*Logout/, "logged in as demo");

# Demo is admin, so go there
$driver->find_element('admin', 'link_text')->click();
is($driver->get_title(), "openQA: Workers", "on workers overview");

# now hack ourselves to be just operator - this is stupid procedure, but we don't have API for user management
$driver->find_element('Users', 'link_text')->click;
$driver->execute_script('$("#users").off("change")');
$driver->execute_script('$("#users").on("change", "input[name=\"role\"]:radio", function() {$(this).parent("form").submit();})');
$driver->find_element('//tr[./td[@class="nick" and text()="Demo"]]/td[@class="role"]//label[2]')->click;

# refresh and return to admin pages
$driver->refresh;
$driver->get($driver->get_current_url =~ s/users//r);
$driver->find_element('admin', 'link_text')->click();

# we should see test templates, groups, machines
for my $item ('Medium types', 'Machines', 'Workers', 'Assets', 'Scheduled products') {
    ok($driver->find_element($item, 'link_text'), "can see $item");
}
# we shouldn't see users, audit
for my $item ('Users', 'Audit log') {
    eval { $driver->find_element($item, 'link_text') };
    ok($@, "can not see $item");
}

t::ui::PhantomTest::kill_phantom();
done_testing();
