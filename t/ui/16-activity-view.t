#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

BEGIN { $ENV{TZ} = 'UTC' }

use Test::Most;

use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Client;
use Date::Format 'time2str';
use Time::Seconds;

use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

driver_missing unless my $driver = call_driver;

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

#                state     result        blocked css class
# from fixtures
my %state_result = (
    99981 => [qw(cancelled skipped            0 fa-times)],
    99926 => [qw(done      incomplete         0 result_incomplete)],
    80000 => [qw(done      passed             0 result_passed)],
    99937 => [qw(done      passed             0 result_passed)],
    99936 => [qw(done      softfailed         0 result_softfailed)],
    99938 => [qw(done      failed             0 result_failed)],
    99927 => [qw(scheduled none               0 state_scheduled)],
    99928 => [qw(scheduled none               0 state_scheduled)],
    99963 => [qw(running   none               0 state_running)],
);
# created during test
my %state_result_create = (
    80001 => [qw(cancelled obsoleted          0 fa-times)],
    80002 => [qw(cancelled parallel_restarted 0 fa-times)],
    80003 => [qw(cancelled skipped            0 fa-times)],
    80004 => [qw(done      obsoleted          0 result_obsoleted)],
    80005 => [qw(done      parallel_failed    0 result_parallel_failed)],
    80006 => [qw(done      parallel_restarted 0 result_parallel_restarted)],
    80007 => [qw(done      skipped            0 result_skipped)],
    80008 => [qw(done      timeout_exceeded   0 result_timeout_exceeded)],
    80009 => [qw(done      user_cancelled     0 result_user_cancelled)],
    80010 => [qw(scheduled none               99963 state_blocked)],
);

subtest 'Current jobs' => sub {
    my $schema = $t->app->schema;
    my $events = $schema->resultset('AuditEvents');

    # The events are interchangeable, but all of these should work
    my %fake_events = (
        80000 => 'job_done',
        99926 => 'job_restart',
        99927 => 'job_update_result',
        99936 => 'job_create',
        99937 => 'job_done',
        (
            map { $_ => 'job_create' } 99981,
            99928, 99963, 99938, 80001, 80002, 80003, 80004, 80005, 80006, 80007, 80008, 80009, 80010
        ));
    my $user = $schema->resultset('Users')->find({is_admin => 1});
    my $jobs = $schema->resultset('Jobs');


    for my $id (sort keys %state_result_create) {
        my $val = $state_result_create{$id};
        my $job = {
            # job with empty value settings as default
            id => $id,
            priority => 50,
            state => $val->[0],
            result => $val->[1],
            TEST => 'minimalx',
            t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 10 * ONE_HOUR, 'UTC'),
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 20 * ONE_HOUR, 'UTC'),
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 20 * ONE_HOUR, 'UTC'),
        };
        if ($val->[2]) {
            $job->{blocked_by_id} = $val->[2];
        }
        $jobs->create($job);
        $state_result{$id} = $val;
    }

    $events->create(
        {
            user_id => $user->id,
            connection_id => 'foo',
            event => $fake_events{$_},
            event_data => "{\"id\": $_}",
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - $_ - 80000, 'UTC'),
        }) for sort keys %fake_events;
    # Multiple events for the same job amount to one item
    $events->create(
        {
            user_id => $user->id,
            connection_id => 'foo',
            event => 'job_restart',
            event_data => "{\"id\": 99936}",
        });
    $driver->refresh;
    wait_for_element(selector => '#results .list-group-item');

    like $driver->get_title(), qr/Activity View/, 'search shown' or return;
    my $results = $driver->find_element_by_id('results');
    my @entries = $results->children('.list-group-item');
    is scalar @entries, 19, '19 jobs' or return diag explain $results->get_text;

    my @rows = $driver->find_elements('#results .list-group-item');
    for my $row (@rows) {
        my @links = $row->children('a');
        my $href = $links[0]->get_attribute('href');
        unless ($href =~ m{/tests/(\d+)}) {
            fail("Link '$href' is not a test url");    # uncoverable statement
            next;
        }
        my $id = $1;
        my $exp = delete $state_result{$id};
        my $exp_class = $exp->[3];
        my @i = $row->children('i');
        my @class = split ' ', $i[0]->get_attribute('class');
        ok((grep { $_ eq $exp_class } @class), "classname contains $exp_class")
          or diag(Data::Dumper->Dump([\@class], ['class']));
    }
    if (keys %state_result) {
        fail "Missed the following jobs in the list:";    # uncoverable statement
        diag(Data::Dumper->Dump([\%state_result], ['state_result']));
    }

    my $first = wait_for_element(selector => '#results .list-group-item:first-child .timeago:not(:empty)');
    is $first->get_text, 'about an hour ago', 'first job';
    my $last = wait_for_element(selector => '#results .list-group-item:last-child .timeago:not(:empty)');
    is $last->get_text, 'about a month ago', 'last job';
};

END { kill_driver() }
done_testing();

# Steps for testing locally
# This way you will get all combinations of job state and result.
# Import db dump from o3 or osd
#   create table job_creations (event_id INT, job_id INT)
#   insert into job_creations select id as event_id, cast(substr(event_data, 7, 7) as integer) as job_id from audit_events where event = 'job_create' and event_data like '{"id"%';
# Copy ids from the following select:
#   select max(jc.event_id) from jobs j INNER join job_creations jc ON j.id=jc.job_id  group by state, result, CASE WHEN blocked_by_id is null THEN '' ELSE 'blocked' END  order by state, result
# Add this in OpenQA::WebAPI::ServerSideDataTable::render_response():
#    push @$filter_conds, {
#        'me.id' => { IN => [
#                1, 2, 3 # ids from previous select
#            ]}};
# Remove encodeURIComponent(currentUser) from openqa.js:renderActivityView()

