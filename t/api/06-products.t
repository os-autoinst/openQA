#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);


$t->get_ok('/api/v1/products')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Products' => [
            {
                'arch'     => 'i586',
                'distri'   => 'opensuse',
                'flavor'   => 'DVD',
                'id'       => 1,
                'settings' => [
                    {
                        'key'   => 'DVD',
                        'value' => '1'
                    },
                    {
                        'key'   => 'ISO_MAXSIZE',
                        'value' => '4700372992'
                    }
                ],
                'version' => '13.1'
            },
            {
                id       => 2,
                distri   => 'sle',
                version  => '12-SP1',
                flavor   => 'Server-DVD-Updates',
                arch     => 'x86_64',
                settings => [],
            },
            {
                id       => 3,
                distri   => 'opensuse',
                version  => '13.1',
                flavor   => 'DVD',
                arch     => 'ppc64',
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
        arch              => "x86_64",
        distri            => "opensuse",
        flavor            => "DVD",
        version           => 13.2,
        "settings[TEST]"  => "val1",
        "settings[TEST2]" => "val1"
    })->status_is(200);
my $product_id = $t->tx->res->json->{id};
my $event      = OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create');
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
                'arch'     => 'x86_64',
                'distri'   => 'opensuse',
                'flavor'   => 'DVD',
                'id'       => $product_id,
                'settings' => [
                    {
                        'key'   => 'TEST',
                        'value' => 'val1'
                    },
                    {
                        'key'   => 'TEST2',
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
                'arch'     => 'x86_64',
                'distri'   => 'opensuse',
                'flavor'   => 'DVD',
                'id'       => $product_id,
                'settings' => [
                    {
                        'key'   => 'TEST2',
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

# switch to operator (percival) and try some modifications
$app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->post_ok(
    '/api/v1/products',
    form => {
        arch              => "x86_64",
        distri            => "opensuse",
        flavor            => "DVD",
        version           => 13.2,
        "settings[TEST]"  => "val1",
        "settings[TEST2]" => "val1"
    })->status_is(403);
$t->put_ok("/api/v1/products/$product_id",
    form => {arch => "x86_64", distri => "opensuse", flavor => "DVD", version => 13.2, "settings[TEST2]" => "val1"})
  ->status_is(403);
$t->delete_ok("/api/v1/products/$product_id")->status_is(403);

done_testing();
