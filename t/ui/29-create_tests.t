#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '15';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $schema = OpenQA::Test::Case->new->init_data;
driver_missing unless my $driver = call_driver;
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

subtest 'navigation to form' => sub {
    $driver->get("$url/login");
    $driver->find_element_by_id('create-tests-action')->click;
    $driver->find_element_by_link_text('Example test')->click;
    $driver->title_is('openQA: Create example test', 'on page to create example test');
};

subtest 'form is pre-filled' => sub {
    my $flash_messages = $driver->find_element_by_id('flash-messages');
    like $flash_messages->get_text, qr/create.*example test.*pre-filled/i, 'note about example present';
    $driver->find_element('#flash-messages button')->click;    # dismiss
    my %expected_values = (
        'create-tests-distri' => 'example',
        'create-tests-version' => '0',
        'create-tests-flavor' => 'DVD',
        'create-tests-arch' => 'x86_64',
        'create-tests-build' => 'openqa',
        'create-tests-test' => 'simple_boot',
        'create-tests-casedir' => 'https://github.com/os-autoinst/os-autoinst-distri-example.git',
        'create-tests-needlesdir' => '',
    );
    is element_prop($_), $expected_values{$_}, "$_ is pre-filled" for keys %expected_values;
};

subtest 'form can be submitted' => sub {
    $driver->find_element('#create-tests-settings-container textarea')->send_keys("_PRIORITY=42\nISO=foo.iso");
    $driver->find_element('#create-tests-form button[type="submit"]')->click;
    wait_for_ajax msg => 'test creation';
    my $flash_messages = $driver->find_element_by_id('flash-messages');
    like $flash_messages->get_text, qr/scheduled.*product log/i, 'note about success';
};

subtest 'settings shown in product log' => sub {
    $driver->find_element_by_link_text('product log')->click;
    $driver->title_is('openQA: Scheduled products log', 'on product log details page');

    my $settings = $driver->find_element('.settings-table')->get_text;
    like $settings, qr/ARCH x86_64/, 'ARCH present';
    like $settings, qr/BUILD openqa/, 'BUILD present';
    like $settings, qr/CASEDIR http.*\.git/, 'CASEDIR present';
    like $settings, qr/DISTRI example/, 'DISTRI present';
    like $settings, qr/FLAVOR DVD/, 'FLAVOR present';
    like $settings, qr/SCENARIO_DEFINITIONS_YAML ---.*products:.*job_templates:/s, 'SCENARIO_DEFINITIONS_YAML present';
    like $settings, qr/TEST simple_boot/, 'TEST present';
    like $settings, qr/VERSION 0/, 'VERSION present';
    like $settings, qr/_PRIORITY 42/, '_PRIORITY present';
    like $settings, qr/ISO foo.iso/, 'ISO present';
};

subtest 'preset not found' => sub {
    $driver->get("$url/tests/create?preset=foo");
    my $flash_messages = $driver->find_element_by_id('flash-messages');
    like $flash_messages->get_text, qr/'foo' does not exist/i, 'error if preset does not exist';
};

subtest 'preset information can be loaded from INI file, note about non-existing scenario definitions' => sub {
    $driver->get("$url/tests/create?preset=bar");
    my $flash_messages = $driver->find_element_by_id('flash-messages')->get_text;
    unlike $flash_messages, qr/does not exist/i, 'preset defined in INI file is available';

    like $flash_messages,
      qr|You first need to clone the .*does-not-exist.* test distribution|i,
      'note about cloning test distribution shown';

    $driver->find_element_by_link_text('Clone')->click;
    my $error_message = wait_for_element selector => '#flash-messages .alert-danger', description => 'error message';
    like $error_message->get_text, qr/No Minion worker available/i, 'expected error shown';
};

kill_driver;
done_testing;
