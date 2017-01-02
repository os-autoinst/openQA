# Copyright (C) 2015 SUSE Linux GmbH
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
use Data::Dumper;

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

sub schema_hook {
    OpenQA::Test::Database->new->create->resultset('Jobs')->search({id => {-in => [99926, 99928]}})
      ->update({assigned_worker_id => 1});
}

my $driver = t::ui::PhantomTest::call_phantom(\&schema_hook);
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is($driver->get_title(), "openQA", "on main page");
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");
# but ...

is($driver->find_element('#user-action', 'css')->get_text(), 'Logged in as Demo', "logged in as demo");

# Demo is admin, so go there
$driver->find_element('#user-action a', 'css')->click();
$driver->find_element('Workers',        'link_text')->click();

is($driver->get_title(), "openQA: Workers", "on workers overview");

is($driver->find_element('tr#worker_1 .worker', 'css')->get_text(), 'localhost:1',  'localhost:1');
is($driver->find_element('tr#worker_2 .worker', 'css')->get_text(), 'remotehost:1', 'remotehost:1');

# we can't check if it's "working" as after 10s the worker is 'dead'
like($driver->find_element('tr#worker_1 .status', 'css')->get_text(), qr/job 99963/, 'on 99963');
like($driver->find_element('tr#worker_2 .status', 'css')->get_text(), qr/job 99961/, 'working 99961');

$driver->find_element('tr#worker_1 .worker a', 'css')->click();

is($driver->get_title(), 'openQA: Worker localhost:1', 'on worker 1');

my $body = $driver->find_element('//body');
like($body->get_text(), qr/Status: .* job 99963/, 'still on 99963');
like($body->get_text(), qr/JOBTOKEN token99963/,  'token for 99963');

# previous jobs table
t::ui::PhantomTest::wait_for_ajax;
my $table = $driver->find_element('#previous_jobs', 'css');
ok($table, 'previous jobs table found');
my @entries = map { $_->get_text() } $driver->find_child_elements($table, 'tbody/tr/td');
is(scalar @entries, 8, 'two previous jobs shown (4 cols per row)');
is_deeply(
    \@entries,
    [
        '99926',      'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
        'incomplete', 'about 2 hours ago',
        '99928',      'opensuse-13.1-DVD-i586-Build0091-RAID1@32bit',
        'none',       'about 2 hours ago',
    ],
    'correct entries shown'
);

t::ui::PhantomTest::kill_phantom();
done_testing();
