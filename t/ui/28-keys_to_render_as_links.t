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
my $scheduled_products = $schema->resultset('ScheduledProducts');
my $product_id = $scheduled_products->create({settings => {__URL => 'https://foo,http://bar test', __NO_URL => 'foo'}});
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
$schema->resultset('Jobs')->find($job_id)
  ->settings->create({key => 'SOME_URLS', value => 'https://foo http://bar http://baz'});

driver_missing unless my $driver = call_driver;
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

$t->get_ok($uri_path_from_root_dir)->status_is(200)
  ->content_like(qr|test|i, 'setting file source found from the root of the test distribution');
$t->get_ok($uri_path_from_default_data_dir)->status_is(200)
  ->content_like(qr|test|i, 'setting file source found in default_data_dir');

$driver->get("/tests/$job_id#settings");
note 'Finding link associated with keys_to_render_as_links';
ok $driver->find_element_by_link($foo_path), 'configured setting key rendered as link';
ok $driver->find_element_by_link('https://foo'), 'multi URL rendered as link (1)';
is $driver->find_element_by_link('https://foo')->get_css_attribute('display'), 'block';
ok $driver->find_element_by_link('http://bar'), 'multi URL rendered as link (2)';
is $driver->find_element_by_link('http://bar')->get_css_attribute('display'), 'block';
ok $driver->find_element_by_link('http://baz'), 'multi URL rendered as link (3)';
is $driver->find_element_by_link('http://baz')->get_css_attribute('display'), 'block';
note 'Making sure that no other settings are rendered as links';
my @number_of_elem = $driver->find_elements('#settings_box a');
is(scalar @number_of_elem, 4, 'only configured setting keys and URLs render as links');
note 'Checking link navigation to the source';
$driver->find_element_by_link($foo_path)->click();
is($driver->get_current_url(), "$url$uri_path_from_root_dir", 'Link is accessed with correct URI');

subtest 'scheduled product settings' => sub {
    $driver->get('/admin/productlog?id=' . $product_id->id);
    my $table = $driver->find_element('#scheduled-products > table');
    like $table->get_text, qr{__NO_URL foo.*__URL https://foo,http://bar test}s, 'text rendered';
    my @links_in_table = $driver->find_elements('#scheduled-products > table a');
    is scalar @links_in_table, 2, 'exactly two links are rendered' or return;
    is $links_in_table[0]->get_text, 'https://foo', 'link text (1)';
    like $links_in_table[0]->get_attribute('href'), qr{^https://foo/?$}, 'link href (1)';
    is $links_in_table[1]->get_text, 'http://bar', 'link text (2)';
    like $links_in_table[1]->get_attribute('href'), qr{^http://bar/?$}, 'link href (2)';
};

kill_driver();
done_testing();
