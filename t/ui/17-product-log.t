#!/usr/bin/env perl

# Copyright (C) 2016-2020 SUSE LLC
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

use Mojo::JSON 'decode_json';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;

use OpenQA::Test::Case;
use OpenQA::Client;

use OpenQA::SeleniumTest;

my $test_case   = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema      = $test_case->init_data(schema_name => $schema_name);

sub schema_hook {
    # simulate typo in START_AFTER_TEST to check for error message in this case
    my $test_suits = $schema->resultset('TestSuites');
    $test_suits->find(1017)->settings->find({key => 'START_AFTER_TEST'})->update({value => 'kda,textmode'});
}

my $driver = call_driver(\&schema_hook);
if (!$driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# setup test application with API access
# note: Test::Mojo loses its app when setting a new ua (see https://github.com/kraih/mojo/issues/598).
my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

# schedule an ISO
$t->post_ok(
    $url . '/api/v1/isos',
    form => {
        ISO     => 'whatever.iso',
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        BUILD   => '0091',
        FOO     => 'bar',
    })->status_is(200);
is($t->tx->res->json->{count}, 9, '9 new jobs created, 1 fails due to wrong START_AFTER_TEST');

# access product log without being logged-in
$driver->get($url . '/admin/productlog');
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
my $table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables present when not logged in');
my @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
is(scalar @rows, 1, 'one row present');
my @restart_buttons = $driver->find_elements('#product_log_table .fa-redo', 'css');
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
    @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
    is(scalar @rows, 1, 'one row for the scheduled iso found');
    my $row = shift @rows;
    @cells = $driver->find_child_elements($row, './td', 'xpath');
    my @cell_contents = map { $_->get_text } @cells;
    ok(shift @cell_contents, 'time present');
    is_deeply(
        \@cell_contents,
        [qw(perci scheduled opensuse 13.1 DVD i586 0091 whatever.iso), ''],
        'row contents match specified scheduling parameter'
    );
};

subtest 'trigger actions' => sub {
    ok($cells[9], 'cell with action buttons displayed');
    my @action_links = $driver->find_child_elements($cells[9], 'a', 'css');
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
    my $results         = decode_json($driver->find_element('.modal-body')->get_text());
    my $failed_job_info = $results->{failed_job_info};
    is(scalar @{$results->{successful_job_ids}}, 9, '9 jobs successful');
    is(scalar @{$failed_job_info},               2, '2 errors present');
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
        'Do you really want to reschedule all jobs for the product?',
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
};

like(
    $driver->find_element_by_id('product_log_table_info')->get_text(),
    qr/Showing 1 to 2 of 2 entries/,
    'Info line shows number of entries'
);
$driver->get($url . '/admin/productlog?entries=1');
like(
    $driver->find_element_by_id('product_log_table_info')->get_text(),
    qr/Showing.*of 1 entries/,
    'Maximum number of entries can be configured by query'
);

kill_driver();
done_testing();
