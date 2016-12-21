# Copyright (C) 2016 SUSE LLC
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

use Mojo::Base;
use Test::More;
use Test::Mojo;
use Test::Warnings;

use OpenQA::Test::Case;
use OpenQA::Client;

use t::ui::PhantomTest;

OpenQA::Test::Case->new->init_data;

my $driver = t::ui::PhantomTest::call_phantom();
if (!$driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

my $t = Test::Mojo->new('OpenQA::WebAPI');
# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . t::ui::PhantomTest::get_mojoport;

# Scheduled isos are only available to operators and admins
$t->get_ok($url . '/admin/auditlog')->status_is(302);
$t->get_ok($url . '/login')->status_is(302);
$t->get_ok($url . '/admin/auditlog')->status_is(200);

# Log in as Demo in phantomjs webui
is($driver->get_title(), "openQA", "on main page");
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");
is($driver->find_element('#user-action', 'css')->get_text(), 'Logged in as Demo', "logged in as demo");

$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Audit log',      'link_text')->click();
# wait until datatables, wait_for_ajax isnt sufficient here, 1s seems enough though
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
like($driver->get_title(), qr/Audit log/, 'on audit log');
my $table = $driver->find_element('#audit_log_table', 'css');
ok($table, 'audit table found');

# search for name, event, date and combination
my $search = $driver->find_element('input.form-control', 'css');
ok($search, 'search box found');

my @entries = $driver->find_child_elements($table, 'tbody/tr');
is(scalar @entries, 3, 'three elements without filter');

$search->send_keys('user:system');
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
@entries = $driver->find_child_elements($table, 'tbody/tr');
is(scalar @entries, 1, 'one element when filtered by user');
$search->clear;
t::ui::PhantomTest::wait_for_ajax;

$search->send_keys('event:user_login');
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
@entries = $driver->find_child_elements($table, 'tbody/tr');
is(scalar @entries, 2, 'two elements when filtered by event');
$search->clear;
t::ui::PhantomTest::wait_for_ajax;

$search->send_keys('newer:today');
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
@entries = $driver->find_child_elements($table, 'tbody/tr');
is(scalar @entries, 3, 'three elements when filtered by today time');
$search->clear;
t::ui::PhantomTest::wait_for_ajax;

$search->send_keys('older:today');
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
@entries = $driver->find_child_elements($table, 'tbody/tr/td');
is(scalar @entries, 1, 'one element when filtered by yesterday time');
is($entries[0]->get_attribute('class'), 'dataTables_empty', 'but datatables are empty');
$search->clear;
t::ui::PhantomTest::wait_for_ajax;

$search->send_keys('user:system event:startup date:today');
t::ui::PhantomTest::wait_for_ajax;
sleep 1;
@entries = $driver->find_child_elements($table, 'tbody/tr');
is(scalar @entries, 1, 'one element when filtered by combination');


t::ui::PhantomTest::kill_phantom();

done_testing();
