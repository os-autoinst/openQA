#!/usr/bin/env perl

# Copyright (C) 2016-2017 SUSE LLC
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;

use OpenQA::Test::Case;
use OpenQA::Client;

use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data;

my $driver = call_driver();
if (!$driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

sub wait_for_data_table {
    wait_for_ajax;
    # TODO: add some wait condition for rendering here
    sleep 1;
}

my $t = Test::Mojo->new('OpenQA::WebAPI');
# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

# Scheduled isos are only available to operators and admins
$t->get_ok($url . '/admin/auditlog')->status_is(302);
$t->get_ok($url . '/login')->status_is(302);
$t->get_ok($url . '/admin/auditlog')->status_is(200);

# Log in as Demo
$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Audit log')->click();
wait_for_data_table;
like($driver->get_title(), qr/Audit log/, 'on audit log');
my $table = $driver->find_element_by_id('audit_log_table');
ok($table, 'audit table found');

# search for name, event, date and combination
my $search = $driver->find_element('input.form-control');
ok($search, 'search box found');

my @entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 3, 'three elements without filter');

$search->send_keys('QA restart');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 1, 'one element when filtered for event data');
like($entries[0]->get_text(), qr/openQA restarted/, 'correct element displayed');
$search->clear;

$search->send_keys('user:system');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 1, 'one element when filtered by user');
$search->clear;

$search->send_keys('event:user_login');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 2, 'two elements when filtered by event');
$search->clear;

$search->send_keys('newer:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 3, 'three elements when filtered by today time');
$search->clear;

$search->send_keys('older:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is(scalar @entries,                     1,                  'one element when filtered by yesterday time');
is($entries[0]->get_attribute('class'), 'dataTables_empty', 'but datatables are empty');
$search->clear;

$search->send_keys('user:system event:startup date:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 1, 'one element when filtered by combination');


kill_driver();

done_testing();
