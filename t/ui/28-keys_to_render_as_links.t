#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '18';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;
use Mojo::File 'path';

my $schema = OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');
# setup openqa.ini with job_settings_ui
$ENV{OPENQA_CONFIG} = "t/data/03-setting-links";
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->app($app);
# t/data holds test files that simulates setting files that can be found in test distributions
$ENV{OPENQA_BASEDIR} = 't/data';

my $job_id = 99938;
my $foo_path = "foo/foo.txt";
my $uri_path_from_root_dir = "/tests/$job_id/settings/$foo_path";
my $uri_path_from_default_data_dir = "/tests/$job_id/settings/bar/foo.txt";

driver_missing unless my $driver = call_driver;
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

$t->get_ok($uri_path_from_root_dir)->status_is(200)
  ->content_like(qr|test|i, 'setting file source found from the root of the test distribution');
$t->get_ok($uri_path_from_default_data_dir)->status_is(200)
  ->content_like(qr|test|i, 'setting file source found in default_data_dir');

$driver->get("/tests/$job_id#settings");
my $element = wait_for_element(selector => '.settings_box a:only-child');
is($element->get_text(), $foo_path, 'Expected filename found as link text');
$element->click();
is($driver->get_current_url(), "$url$uri_path_from_root_dir", 'Link is accessed with correct URI');

kill_driver();
done_testing();
