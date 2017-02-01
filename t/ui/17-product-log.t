#! /usr/bin/perl

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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base;
use Test::More;
use Test::Mojo;
use Test::Warnings;

use OpenQA::Test::Case;
use OpenQA::Client;

use t::ui::PhantomTest;

OpenQA::Test::Case->new->init_data;

my $driver = call_phantom();
if (!$driver) {
    plan skip_all => $t::ui::PhantomTest::phantommissing;
    exit(0);
}

my $t = Test::Mojo->new('OpenQA::WebAPI');
# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . t::ui::PhantomTest::get_mojoport;

# Scheduled isos are only available to operators and admins
$t->get_ok($url . '/admin/productlog')->status_is(302);
$t->get_ok($url . '/login')->status_is(302);
$t->get_ok($url . '/admin/productlog')->status_is(200);

# Schedule iso - need UA change to add security headers
# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret = $t->post_ok(
    $url . '/api/v1/isos',
    form => {
        ISO     => 'whatever.iso',
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        BUILD   => '0091'
    })->status_is(200);
is($ret->tx->res->json->{count}, 10, '10 new jobs created');

# Log in as Demo in phantomjs webui
$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
is($driver->find_element_by_id('user-action')->get_text(), 'Logged in as Demo', "logged in as demo");

# Test Scheduled isos are displayed
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Scheduled products')->click();
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
my $table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables found');

my @rows  = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
my $nrows = scalar @rows;
my $row   = shift @rows;
my $cell  = $driver->find_child_element($row, './td[2]', 'xpath');
is($cell->get_text, 'opensuse', 'ISO scheduled for opensuse distri');
$cell = $driver->find_child_element($row, './td[8]/span', 'xpath');
like($cell->get_attribute('title'), qr/"ARCH": "i586"/, 'ISO data present');
$cell = $driver->find_child_element($row, './td[1]/a', 'xpath');
my ($id) = $cell->get_attribute('href') =~ m{$url/admin/auditlog\?eventid=(\d)};
ok($id, 'time is actually link to event id');

# Replay works for operator (perci)
$cell = $driver->find_child_element($row, './td[9]/a', 'xpath');
like($cell->get_attribute('href'), qr{$url/api/v1/isos}, 'replay action poinst to isos api route');
$cell->click();
$driver->refresh;
# refresh page
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Scheduled products')->click();
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
$table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables found');
@rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
is(scalar @rows, $nrows + 1, 'iso rescheduled by replay action');

kill_phantom();

done_testing();
