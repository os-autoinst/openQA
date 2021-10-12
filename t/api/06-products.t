#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'), apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');


$t->get_ok('/api/v1/products')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Products' => [
            {
                'arch' => 'i586',
                'distri' => 'opensuse',
                'flavor' => 'DVD',
                'id' => 1,
                'settings' => [
                    {
                        'key' => 'DVD',
                        'value' => '1'
                    },
                    {
                        'key' => 'ISO_MAXSIZE',
                        'value' => '4700372992'
                    }
                ],
                'version' => '13.1'
            },
            {
                id => 2,
                distri => 'sle',
                version => '12-SP1',
                flavor => 'Server-DVD-Updates',
                arch => 'x86_64',
                settings => [],
            },
            {
                id => 3,
                distri => 'opensuse',
                version => '13.1',
                flavor => 'DVD',
                arch => 'ppc64',
                settings => [],
            }]
    },
    "Initial products"
) || diag explain $t->tx->res->json;


# no arch
$t->post_ok('/api/v1/products', form => {distri => "opensuse", flavor => "DVD", version => 13.2})->status_is(400);

# no distri
$t->post_ok('/api/v1/products', form => {arch => "x86_64", flavor => "DVD", version => 13.2})->status_is(400);

# no flavor
$t->post_ok('/api/v1/products', form => {arch => "x86_64", distri => "opensuse", version => 13.2})->status_is(400);

# no version
$t->post_ok('/api/v1/products', form => {arch => "x86_64", distri => "opensuse", flavor => "DVD"})->status_is(400);

$t->post_ok(
    '/api/v1/products',
    form => {
        arch => "x86_64",
        distri => "opensuse",
        flavor => "DVD",
        version => 13.2,
        "settings[TEST]" => "val1",
        "settings[TEST2]" => "val1"
    })->status_is(200);
my $product_id = $t->tx->res->json->{id};
my $event = OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create');
is_deeply(
    [sort keys %$event],
    ['arch', 'description', 'distri', 'flavor', 'id', 'name', 'settings', 'table', 'version'],
    'product event was logged correctly'
);

$t->post_ok('/api/v1/products', form => {arch => "x86_64", distri => "opensuse", flavor => "DVD", version => 13.2})
  ->status_is(400);    #already exists

$t->get_ok("/api/v1/products/$product_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Products' => [
            {
                'arch' => 'x86_64',
                'distri' => 'opensuse',
                'flavor' => 'DVD',
                'id' => $product_id,
                'settings' => [
                    {
                        'key' => 'TEST',
                        'value' => 'val1'
                    },
                    {
                        'key' => 'TEST2',
                        'value' => 'val1'
                    }
                ],
                'version' => '13.2'
            }]
    },
    "Add product"
) || diag explain $t->tx->res->json;

$t->put_ok("/api/v1/products/$product_id",
    form => {arch => "x86_64", distri => "opensuse", flavor => "DVD", version => 13.2, "settings[TEST2]" => "val1"})
  ->status_is(200);

$t->get_ok("/api/v1/products/$product_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Products' => [
            {
                'arch' => 'x86_64',
                'distri' => 'opensuse',
                'flavor' => 'DVD',
                'id' => $product_id,
                'settings' => [
                    {
                        'key' => 'TEST2',
                        'value' => 'val1'
                    }
                ],
                'version' => '13.2'
            }]
    },
    "Delete product variable"
) || diag explain $t->tx->res->json;

$t->delete_ok("/api/v1/products/$product_id")->status_is(200);
$t->delete_ok("/api/v1/products/$product_id")->status_is(404);    #not found

# switch to operator (default client) and try some modifications
client($t);
$t->post_ok(
    '/api/v1/products',
    form => {
        arch => "x86_64",
        distri => "opensuse",
        flavor => "DVD",
        version => 13.2,
        "settings[TEST]" => "val1",
        "settings[TEST2]" => "val1"
    })->status_is(403);
$t->put_ok("/api/v1/products/$product_id",
    form => {arch => "x86_64", distri => "opensuse", flavor => "DVD", version => 13.2, "settings[TEST2]" => "val1"})
  ->status_is(403);
$t->delete_ok("/api/v1/products/$product_id")->status_is(403);

done_testing();
