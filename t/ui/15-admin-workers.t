#! /usr/bin/perl

# Copyright (C) 2015-2018 SUSE LLC
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

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use Date::Format 'time2str';

use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ws = OpenQA::WebSockets->new;
my $sh = OpenQA::Scheduler->new;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use OpenQA::SeleniumTest;

sub schema_hook {
    OpenQA::Test::Database->new->create->resultset('Jobs')->search({id => {-in => [99926, 99961]}})
      ->update({assigned_worker_id => 1});
}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

$driver->title_is("openQA", "on main page");

# without loggin we hide properties of worker
$driver->get('/admin/workers/1');
$driver->title_is('openQA: Worker localhost:1', 'on worker 1');
is(scalar @{$driver->find_elements('h3', 'css')}, 1, 'table properties hidden');

$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
# but ...

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

# Demo is admin, so go there
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Workers')->click();

$driver->title_is("openQA: Workers", "on workers overview");

$driver->find_element_by_xpath("//select[\@id='workers_online']/option[1]")->click();

is($driver->find_element('tr#worker_1 .worker')->get_text(), 'localhost:1',  'localhost:1');
is($driver->find_element('tr#worker_2 .worker')->get_text(), 'remotehost:1', 'remotehost:1');

# we can't check if it's "working" as after 10s the worker is 'dead'
$driver->find_element('tr#worker_1 .help_popover')->click();
like($driver->find_element('.popover')->get_text(), qr/Worker status\nJob: 99963/, 'on 99963');
$driver->find_element('.paginate_button')->click();
$driver->find_element('tr#worker_2 .help_popover')->click();
# FIXME: select right .popover element
# it works when testing manually, you can actually see the right popover when using NOT_HEADLESS=1
#like($driver->find_element('.popover')->get_text(), qr/Worker status\nJob: 99961/, 'working 99961');

$driver->find_element('tr#worker_1 .worker a')->click();

$driver->title_is('openQA: Worker localhost:1', 'on worker 1');
is(scalar @{$driver->find_elements('#content h3', 'css')}, 2, 'table properties shown');

$driver->find_element('.help_popover')->click();
my $body = $driver->find_element_by_xpath('//body');

like($body->get_text(), qr/Worker status\nJob: 99963/, 'still on 99963');
like($body->get_text(), qr/JOBTOKEN token99963/,       'token for 99963');

# previous jobs table
wait_for_ajax;
my $table = $driver->find_element_by_id('previous_jobs');
ok($table, 'previous jobs table found');
my @entries = map { $_->get_text() } $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is(scalar @entries, 6, 'two previous jobs shown (3 cols per row)');
is_deeply(
    \@entries,
    [
        'opensuse-13.1-NET-x86_64-Build0091-kde@64bit',
        '', 'not yet', 'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
        '0', 'about an hour ago',
    ],
    'correct entries shown'
);

# restart running job assigned to a worker
$driver->find_child_element($table, 'a.restart', 'css')->click();
wait_for_ajax;
$table = $driver->find_element_by_id('previous_jobs');
ok($table, 'still on same page (with table)');
@entries = map { $_->get_text() } $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is_deeply(
    \@entries,
    [
        'opensuse-13.1-NET-x86_64-Build0091-kde@64bit (restarted)',
        '', 'not yet', 'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
        '0', 'about an hour ago',
    ],
    'the first job has been restarted'
);

kill_driver();
done_testing();
