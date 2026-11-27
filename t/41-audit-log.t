#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Date::Format 'time2str';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

# init test case
my $test_case = OpenQA::Test::Case->new(config_directory => "$FindBin::Bin/data/41-audit-log");
my $schema = $test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# get resultsets
my $events = $schema->resultset('AuditEvents');

# clear any existing audit events; we don't want to use fixtures here
$events->search({})->delete;

# insert fake events
my %fake_events = (
    1000 => 'startup',
    1010 => 'table_create',
    1011 => 'table_update',
    1020 => 'jobtemplate_create',
    1021 => 'jobtemplate_update',
    1030 => 'jobgroup_connect',
    1031 => 'jobgroup_update',
    1040 => 'needle_modify',
    1050 => 'user_login',
    1060 => 'iso_create',
    1061 => 'iso_cancel',
    1070 => 'asset_register',
    1071 => 'asset_delete',
    1080 => 'other_event',
    1081 => 'yet_other_event',
);
my $user = $schema->resultset('Users')->create_user('foo', is_admin => 1, is_operator => 1);
$events->create(
    {
        id => $_,
        user_id => $user->id,
        connection_id => 'foo',
        event => $fake_events{$_},
        event_data => '{"foo" => "bar"}',
    }) for keys %fake_events;

# define test helper
sub all_events_ids () {
    return [sort map { $_->id } $events->all];
}

sub make_time ($days_ago) {
    my $seconds_per_day = 60 * 60 * 24;
    return time2str('%Y-%m-%d %H:%M:%S', time - ($seconds_per_day * $days_ago), 'UTC');
}

sub assume_all_events_before_x_days ($days_ago) {
    my $date = make_time($days_ago);
    $events->search({})->update({t_created => $date});
}

sub assume_events_being_deleted (@event_ids) {
    delete $fake_events{$_} for (@event_ids);
}

# note: The tested time constraints are defined in t/data/41-audit-log/openqa.ini.

subtest 'server-side sorting' => sub {
    $events->search({})->update({t_created => make_time(0)});
    $t->get_ok('/')->status_is(200);
    ok $test_case->login($t, 'foo'), 'logged in as admin';

    my @sorted_ids = sort { $a <=> $b } map { 0 + $_ } keys %fake_events;
    my $ajax_ids = sub ($dir) {
        my $url = '/admin/auditlog/ajax?draw=1&start=0&length=100&order%5B0%5D%5Bcolumn%5D=1';
        my $data = $t->get_ok("$url&order%5B0%5D%5Bdir%5D=$dir")->status_is(200)->tx->res->json->{data};
        return [map { $_->{id} } @$data];
    };
    is_deeply $ajax_ids->('desc'), [reverse @sorted_ids], 'descending time sort breaks ties on descending id';
    is_deeply $ajax_ids->('asc'), \@sorted_ids, 'ascending time sort breaks ties on ascending id';
};

$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'all events considered recent enough to be kept';

assume_all_events_before_x_days(15);
assume_events_being_deleted(1080, 1081);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'other events deleted after 10 days';

assume_all_events_before_x_days(25);
assume_events_being_deleted(1000);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'startup events deleted after 20 days';

assume_all_events_before_x_days(35);
assume_events_being_deleted(1030, 1031);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'job group events deleted after 30 days';

assume_all_events_before_x_days(45);
assume_events_being_deleted(1020, 1021);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'job template events deleted after 40 days';

assume_all_events_before_x_days(55);
assume_events_being_deleted(1010, 1011);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'table events deleted after 50 days';

assume_all_events_before_x_days(65);
assume_events_being_deleted(1060, 1061);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'iso events deleted after 60 days';

assume_all_events_before_x_days(75);
assume_events_being_deleted(1050);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'user events deleted after 70 days';

assume_all_events_before_x_days(85);
assume_events_being_deleted(1070, 1071);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'asset events deleted after 80 days';

assume_all_events_before_x_days(95);
assume_events_being_deleted(1040);
$events->delete_expired_entries;
is_deeply all_events_ids, [sort keys %fake_events], 'needle events deleted after 90 days';

done_testing();
