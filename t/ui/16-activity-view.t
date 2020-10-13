#!/usr/bin/env perl
# Copyright (C) 2020 SUSE LLC
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

use Date::Format 'time2str';
use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Client;

use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

plan skip_all => $OpenQA::SeleniumTest::drivermissing unless my $driver = call_driver;

my $t = Test::Mojo->new('OpenQA::WebAPI');
# we need to talk to the phantom instance or else we're using the wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

subtest 'Access activity view via the menu' => sub {
    $driver->find_element_by_link_text('Login')->click();
    $driver->title_is('openQA', 'on main page');
    is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', 'logged in as demo');
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Activity View')->click();
    $driver->title_is('openQA: Personal Activity View', 'on activity view');
};

subtest 'Current jobs' => sub {
    my $schema = $t->app->schema;
    my $events = $schema->resultset('AuditEvents');

    # The events are interchangeable, but all of these should work
    my %fake_events = (
        80000 => 'job_done',             # passed
        99926 => 'job_restart',          # incomplete+reason
        99927 => 'job_update_result',    # scheduled,
        99936 => 'job_create',           # softfailed
        99937 => 'job_done',             # passed,
    );
    my $user = $schema->resultset('Users')->find({is_admin => 1});
    my $jobs = $schema->resultset('Jobs');
    $events->create(
        {
            user_id       => $user->id,
            connection_id => 'foo',
            event         => $fake_events{$_},
            event_data    => "{\"id\": $_}",
            t_created     => time2str('%Y-%m-%d %H:%M:%S', time - $_ - 80000, 'UTC'),
        }) for sort keys %fake_events;
    # Multiple events for the same job amount to one item
    $events->create(
        {
            user_id       => $user->id,
            connection_id => 'foo',
            event         => 'job_restart',
            event_data    => "{\"id\": 99936}",
        });
    $driver->refresh;
    wait_for_element(selector => '#results .list-group-item');

    like $driver->get_title(), qr/Activity View/, 'search shown' or return;
    my $results = $driver->find_element_by_id('results');
    my @entries = $results->children('.list-group-item');
    is scalar @entries, 5, '5 jobs' or return diag explain $results->get_text;

    my $first = wait_for_element(selector => '#results .list-group-item:first-child .timeago:not(:empty)');
    is $first->get_text, 'about 2 hours ago', 'first job';
    my $last = wait_for_element(selector => '#results .list-group-item:last-child .timeago:not(:empty)');
    is $last->get_text, '6 days ago', 'last job';
};

END { kill_driver() }
done_testing();
