#!/usr/bin/env perl
# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';

use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Client;

use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data;
driver_missing unless my $driver = call_driver;

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
my $search = $driver->find_element('#audit_log_table_filter input.form-control');
ok($search, 'search box found');

my @entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 4, 'elements without filter');

$search->send_keys('QA restart');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 2, 'less elements when filtered for event data');
like($entries[0]->get_text(), qr/openQA restarted/, 'correct element displayed');
$search->clear;

$search->send_keys('user:system');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 2, 'less elements when filtered by user');
$search->clear;

$search->send_keys('event:user_login');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 2, 'two elements when filtered by event');
$search->clear;

$search->send_keys('newer:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 4, 'elements when filtered by today time');
$search->clear;

$search->send_keys('older:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is(scalar @entries, 1, 'one element when filtered by yesterday time');
is($entries[0]->get_attribute('class'), 'dataTables_empty', 'but datatables are empty');
$search->clear;

$search->send_keys('user:system event:startup date:today');
wait_for_data_table;
@entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
is(scalar @entries, 2, 'elements when filtered by combination');


subtest 'clickable events' => sub {
    # Populate database via the API to add events without hard-coding the format here
    my $auth = {'X-CSRF-Token' => $t->ua->get($url . '/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
    $t->post_ok($url . '/api/v1/machines', $auth => form => {name => 'foo', backend => 'qemu'})->status_is(200);
    $t->post_ok($url . '/api/v1/test_suites', $auth => form => {name => 'testsuite'})->status_is(200);
    $t->post_ok(
        $url . '/api/v1/products',
        $auth => form => {
            arch => 'x86_64',
            distri => 'opensuse',
            flavor => 'DVD',
            version => '13.2',
        })->status_is(200);
    ok OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create'), 'event emitted';

    $driver->refresh();
    wait_for_ajax;
    $search = $driver->find_element('#audit_log_table_filter input.form-control');
    $search->send_keys('event:table_create');
    wait_for_data_table;
    $table = $driver->find_element_by_id('audit_log_table');
    @entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
    is(scalar @entries, 3, 'three elements') or return diag $_->get_text for @entries;
    ok($entries[0]->child('.audit_event_details'), 'event detail link present');
};

kill_driver();

done_testing();
