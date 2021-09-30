#!/usr/bin/env perl
# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Module::Load::Conditional qw(can_load);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Date::Format;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '16';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '01-jobs.pl 02-workers.pl');
my $parent_groups = $schema->resultset('JobGroupParents');

sub prepare_database {
    my $job_groups = $schema->resultset('JobGroups');
    my $jobs = $schema->resultset('Jobs');
    # add job groups from fixtures to new parent
    my $parent_group = $parent_groups->create({name => 'Test parent', sort_order => 0});
    while (my $job_group = $job_groups->next) {
        $job_group->update(
            {
                parent_id => $parent_group->id
            });
    }
    # add data to test same name job group within different parent group
    my $parent_group2 = $parent_groups->create({name => 'Test parent 2', sort_order => 1});
    my $new_job_group = $job_groups->create({name => 'opensuse', parent_id => $parent_group2->id});
    my $new_job = $jobs->create(
        {
            id => 100001,
            group_id => $new_job_group->id,
            result => "none",
            state => "cancelled",
            priority => 35,
            t_finished => undef,
            # 10 minutes ago
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),
            # Two hours ago
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            TEST => "upgrade",
            ARCH => 'x86_64',
            BUILD => '0100',
            DISTRI => 'opensuse',
            FLAVOR => 'NET',
            MACHINE => '64bit',
            VERSION => '13.1',
            result_dir => '00099961-opensuse-13.1-DVD-x86_64-Build0100-kde',
            settings => [
                {key => 'DESKTOP', value => 'kde'},
                {key => 'ISO_MAXSIZE', value => '4700372992'},
                {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0100-Media.iso'},
                {key => 'DVD', value => '1'},
            ]});
}

prepare_database();

driver_missing unless my $driver = call_driver;

# DO NOT MOVE THIS INTO A 'use' FUNCTION CALL! It will cause the tests
# to crash if the module is unavailable
plan skip_all => 'Install Selenium::Remote::WDKeys to run this test'
  unless can_load(modules => {'Selenium::Remote::WDKeys' => undef,});

# don't tests basics here again, this is already done in t/22-dashboard.t and t/ui/14-dashboard.t

$driver->title_is('openQA', 'on main page');
my $baseurl = $driver->get_current_url();

$driver->get($baseurl . '?limit_builds=20');
wait_for_ajax_and_animations;

# test expanding/collapsing
is(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, 'link to child group collapsed (in the first place)');
$driver->find_element_by_link_text('Build0091')->click();
my $element = $driver->find_element_by_link_text('opensuse');
ok($element->is_displayed(), 'link to child group expanded');
$driver->find_element_by_link_text('Build0091')->click();
# Looking for "is_hidden" does not turn out to be reliable so relying on xpath
# lookup of collapsed entries instead
ok($driver->find_element_by_xpath('//div[contains(@class,"children-collapsed")]//a'), 'link to child group collapsed');

# go to parent group overview
$driver->find_element_by_link_text('Test parent')->click();
wait_for_ajax_and_animations;
ok($driver->find_element('#group1_build13_1-0091 .h4 a')->is_displayed(), 'link to child group displayed');
my @links = $driver->find_elements('.h4 a', 'css');
is(scalar @links, 19, 'all links expanded in the first place');
$driver->find_element_by_link_text('Build0091')->click();
ok($driver->find_element('#group1_build13_1-0091 .h4 a')->is_hidden(), 'link to child group collapsed');

# check same name group within different parent group
isnt(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, "child group 'opensuse' in 'Test parent'");

# back to home and go to another parent group overview
$driver->find_element_by_class('navbar-brand')->click();
wait_for_ajax(msg => 'wait until job group results show up');
$driver->find_element_by_link_text('Test parent 2')->click();
wait_for_ajax_and_animations;
isnt(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, "child group 'opensuse' in 'Test parent 2'");

# test filtering for nested groups
subtest 'filtering subgroups' => sub {
    $driver->get('/');
    wait_for_ajax_and_animations;
    my $url = $driver->get_current_url;
    $driver->find_element('#filter-panel .card-header')->click();
    $driver->find_element_by_id('filter-group')->send_keys('Test parent / .* test$');
    $driver->find_element_by_id('filter-default-expanded')->click();
    my $ele = $driver->find_element_by_id('filter-limit-builds');
    $ele->click();
    $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{end}, '0');    # appended
    $ele = $driver->find_element_by_id('filter-time-limit-days');
    $ele->click();
    $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{end}, '0');    # appended
    $driver->find_element('#filter-apply-button')->click();
    wait_for_ajax();
    $url .= '?group=Test%20parent%20%2F%20.*%20test%24';
    $url .= '&default_expanded=1&limit_builds=30&time_limit_days=140&interval=';
    is($driver->get_current_url, $url, 'URL parameters for filter are correct');
    is(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, "child group 'opensuse' filtered out");
    isnt(scalar @{$driver->find_elements('opensuse test', 'link_text')}, 0, "child group 'opensuse test' present'");
};

subtest 'View grouped by group' => sub {
    $driver->get('/parent_group_overview/' . $parent_groups->find({name => 'Test parent'})->id);
    $driver->find_element_by_id('grouped_by_group_tab')->click();
    is(
        $driver->find_element_by_id('grouped_by_group_tab')->get_attribute('class'),
        'active parent_group_overview_grouping_active',
        'grouped by group link not active'
    );
    isnt(
        $driver->find_element_by_id('grouped_by_build_tab')->get_attribute('class'),
        'active parent_group_overview_grouping_active',
        'grouped by group link remains active'
    );
    $driver->find_element_by_id('grouped_by_group')->is_displayed();
};

kill_driver();
done_testing();
