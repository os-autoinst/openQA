#!/usr/bin/env perl
# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '12';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $users = $schema->resultset('Users');

driver_missing unless my $driver = call_driver;
disable_timeout;

subtest 'tour does not appear for demo user' => sub {
    $driver->find_element_by_link_text('Login')->click();
    $driver->title_is('openQA', 'on main page');
    is(scalar(@{$driver->find_elements('#step-0')}), 0, 'tour not shown');
};

subtest 'tour shown for new user' => sub {
    $driver->get('/login?user=nobody');
    wait_for_element(selector => '#step-0', is_displayed => 1, description => 'tour popover is displayed');
    is($driver->find_element('h3.popover-header')->get_text(), 'All tests area');
};

subtest 'do the tour and quit' => sub {
    $driver->find_element_by_id('tour-next')->click();
    wait_for_element(selector => '#step-1', is_displayed => 1, description => 'tour popover is displayed');
    $driver->find_element_by_id('tour-end')->click();
    wait_for_ajax(msg => 'quit submitted');
    is(scalar(@{$driver->find_elements('#step-0')}), 0, 'tour not shown anymore');
    $driver->refresh();
    is(scalar(@{$driver->find_elements('#step-0')}), 0, 'tour not shown again after refresh');
};

subtest 'tour can be completely dismissed' => sub {
    $driver->get('/login?user=otherdeveloper');
    $driver->find_element_by_id('dont-notify')->click();
    $driver->find_element_by_id('tour-end')->click();
    wait_for_ajax(msg => 'dismissal submitted');
    is(scalar(@{$driver->find_elements('#step-0')}), 0, 'tour gone');
    is($users->find({nickname => 'otherdeveloper'})->feature_version, 0, 'feature version set to 0');
    $driver->refresh();
    is(scalar(@{$driver->find_elements('#step-0')}), 0, 'tour not shown again');
};

kill_driver();
done_testing();
