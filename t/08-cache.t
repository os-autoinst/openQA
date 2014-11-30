#!/usr/bin/env perl -w

# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use strict;
use openqa;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;

use_ok 'Mojolicious::Plugin::CHI';

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $t = Test::Mojo->new('OpenQA');

my $app = $t->app;

my $hash = {};

$app->plugin(
    CHI => {
        default => {
            driver => 'Memory',
            global => 1
        },
        TestCache => {
            driver => 'Memory',
            datastore => $hash
        }
    }
);

my $c = Mojolicious::Controller->new;
$c->app($app);

# Test TestCache cache
my $test_cache = $c->chi('TestCache');
ok($test_cache, 'CHI handle');

ok($test_cache->set(key_1 => 'Key1'), 'Key1');
ok($test_cache->set(key_2 => 'Key2'), 'Key2');
ok($test_cache->set(key_3 => 'Key3'), 'Key3');

is($test_cache->get('key_1'), 'Key1', 'Key1');
is($test_cache->get('key_2'), 'Key2', 'Key2');
is($test_cache->get('key_3'), 'Key3', 'Key3');

# Test default cache
ok(!$c->chi->get('key_1'), 'No value');
ok(!$c->chi->get('key_2'), 'No value');
ok(!$c->chi->get('key_3'), 'No value');

ok($c->chi->set('key_1' => '_Key1'), '_Key1');
ok($c->chi->set('key_2' => '_Key2'), '_Key2');
ok($c->chi->set('key_3' => '_Key3'), '_Key3');

is($c->chi->get('key_1'), '_Key1', '_Key1');
is($c->chi->get('key_2'), '_Key2', '_Key2');
is($c->chi->get('key_3'), '_Key3', '_Key3');

done_testing();
