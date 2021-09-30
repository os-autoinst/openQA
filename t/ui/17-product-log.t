#!/usr/bin/env perl

# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Mojo::JSON 'decode_json';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $fixtures = '01-jobs.pl 03-users.pl 04-products.pl';
my $schema = $test_case->init_data(schema_name => $schema_name, fixtures_glob => $fixtures);

# simulate typo in START_AFTER_TEST to check for error message in this case
$schema->resultset('TestSuites')->find(1017)->settings->find({key => 'START_AFTER_TEST'})
  ->update({value => 'kda,textmode'});

driver_missing unless my $driver = call_driver;

my $t = client;

# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

# schedule an ISO
$t->post_ok(
    $url . '/api/v1/isos',
    form => {
        ISO => 'whatever.iso',
        DISTRI => 'opensuse',
        VERSION => '13.1',
        FLAVOR => 'DVD',
        ARCH => 'i586',
        BUILD => '0091',
        FOO => 'bar',
    })->status_is(200);
is($t->tx->res->json->{count}, 9, '9 new jobs created, 1 fails due to wrong START_AFTER_TEST');

# access product log without being logged-in
$driver->get($url . '/admin/productlog');
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
my $table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables present when not logged in');
my @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
is(scalar @rows, 1, 'one row present');
my @restart_buttons = $driver->find_elements('#product_log_table .fa-undo', 'css');
is(scalar @restart_buttons, 0, 'no restart buttons present when not logged in');

# log in as Demo
$driver->find_element_by_link_text('Login')->click();
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', 'logged in as demo');

my @cells;

subtest 'scheduled product displayed' => sub {
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Scheduled products')->click();
    like($driver->get_title(), qr/Scheduled products log/, 'on product log');
    $table = $driver->find_element_by_id('product_log_table');
    ok($table, 'products tables found');
    wait_for_ajax(msg => 'server-side scheduled products table');
    @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
    is(scalar @rows, 1, 'one row for the scheduled iso found');
    my $row = shift @rows;
    @cells = $driver->find_child_elements($row, './td', 'xpath');
    my @cell_contents = map { $_->get_text } @cells;
    ok(shift @cell_contents, 'ID present');
    ok(shift @cell_contents, 'time present');
    is_deeply(
        \@cell_contents,
        [qw(perci scheduled opensuse 13.1 DVD i586 0091 whatever.iso), ''],
        'row contents match specified scheduling parameter'
    );
};

subtest 'trigger actions' => sub {
    ok($cells[9], 'cell with action buttons displayed');
    my @action_links = $driver->find_child_elements($cells[10], 'a', 'css');
    is(scalar @action_links, 3, 'all action links present');

    # prevent animation and scroll to the right to ensure buttons are visible/clickable (the table might overflow)
    $driver->execute_script('$("#scheduled-product-modal").removeClass("fade");');
    $driver->execute_script('$("body, html").scrollLeft($(document).outerWidth() - $(window).width());');

    # show settings
    $action_links[0]->click();
    like($driver->find_element('.modal-body')->get_text(), qr/.*FOO.*bar.*/, 'additional parameter shown');
    $driver->find_element('.modal-footer button')->click();

    # show results
    $action_links[1]->click();
    wait_for_ajax;
    my $results = decode_json($driver->find_element('.modal-body')->get_text());
    my $failed_job_info = $results->{failed_job_info};
    is(scalar @{$results->{successful_job_ids}}, 9, '9 jobs successful');
    is(scalar @{$failed_job_info}, 2, '2 errors present');
    is_deeply(
        $failed_job_info->[0]->{error_messages},
        ['START_AFTER_TEST=kda@64bit not found - check for dependency typos and dependency cycles'],
        'error message'
    );
    is_deeply(
        $failed_job_info->[1]->{error_messages},
        ['textmode@32bit has no child, check its machine placed or dependency setting typos'],
        'error message'
    );
    $driver->find_element('.modal-footer button')->click();

    # trigger rescheduling
    $action_links[2]->click();
    is(
        $driver->get_alert_text,
        'Do you really want to reschedule all jobs for the product 1?',
        'confirmation prompt shown'
    );
    $driver->accept_alert;
    wait_for_ajax;
    is(
        $driver->find_element('#flash-messages span')->get_text(),
        'Re-scheduling the product has been triggered. A new scheduled product should appear when refreshing the page.',
        'flash with info message occurs'
    );
};

subtest 'rescheduled ISO shown after refreshing page' => sub {
    $driver->refresh;
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Scheduled products')->click();
    like($driver->get_title(), qr/Scheduled products log/, 'on product log');
    $table = $driver->find_element_by_id('product_log_table');
    ok($table, 'products tables found');
    @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
    is(scalar @rows, 2, 'rescheduled ISO shown');
    like(
        $driver->find_element_by_id('product_log_table_info')->get_text(),
        qr/Showing 1 to 2 of 2 entries/,
        'Info line shows number of entries'
    );
    $driver->find_element('#product_log_table_filter input')->send_keys('whatever.iso');
    wait_for_ajax(msg => 'search applied');
    @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
    is(scalar @rows, 2, 'still two ISOs shown');
    $driver->find_element('#product_log_table_filter input')->send_keys('foo');
    wait_until(
        sub {
            scalar @{$driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath')} == 0;
        },
        'scheduled products filtered out',
    );
};

subtest 'showing a particular scheduled product' => sub {
    $driver->get($url . '/admin/productlog?id=1');
    is($driver->find_element('#scheduled-products h2')->get_text(), 'Scheduled product 1', 'header for specific ID');
    wait_for_ajax(msg => 'server-side scheduled products table');
    my @rows = $driver->find_elements('#product_log_table tbody tr');
    is(scalar @rows, 1, 'only one row shown');
    like($rows[0]->get_text, qr/perci.*whatever\.iso/, 'row data');
    like($driver->find_element('#scheduled-products h3 + table')->get_text, qr/FOO.*bar/, 'settings');
    like($driver->find_element('#scheduled-products h3 + pre')->get_text,
        qr/check for dependency typos and dependency cycles/, 'results');
};

kill_driver();
done_testing();
