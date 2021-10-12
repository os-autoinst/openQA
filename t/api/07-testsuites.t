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
$t->get_ok('/api/v1/test_suites')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'TestSuites' => [
            {
                'id' => 1001,
                'name' => 'textmode',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'textmode'
                    },
                    {
                        'key' => 'VIDEOMODE',
                        'value' => 'text'
                    }]
            },
            {
                'id' => 1002,
                'name' => 'kde',
                'description' => 'Simple kde test, before advanced_kde',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'kde'
                    }]
            },
            {
                'id' => 1013,
                'name' => 'RAID0',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key' => 'INSTALLONLY',
                        'value' => '1'
                    },
                    {
                        'key' => 'RAIDLEVEL',
                        'value' => '0'
                    }]
            },
            {
                'id' => 1014,
                'name' => 'client1',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key' => 'PARALLEL_WITH',
                        'value' => 'server'
                    },
                    {
                        'key' => 'PRECEDENCE',
                        'value' => 'wontoverride'
                    }]
            },
            {
                'id' => 1015,
                'name' => 'server',
                'settings' => [
                    {
                        'key' => '+PRECEDENCE',
                        'value' => 'overridden'
                    },
                    {
                        'key' => 'DESKTOP',
                        'value' => 'textmode'
                    }]
            },
            {
                'id' => 1016,
                'name' => 'client2',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'textmode'
                    },
                    {
                        'key' => 'PARALLEL_WITH',
                        'value' => 'server'
                    }]
            },
            {
                'id' => 1017,
                'name' => 'advanced_kde',
                'description' => 'See kde for simple test',
                'settings' => [
                    {
                        'key' => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key' => 'PUBLISH_HDD_1',
                        'value' => '%DISTRI%-%VERSION%-%ARCH%-%DESKTOP%-%QEMUCPU%.qcow2'
                    },
                    {
                        'key' => 'START_AFTER_TEST',
                        'value' => 'kde,textmode'
                    }]}]
    },
    "Initial test suites"
) || diag explain $t->tx->res->json;

$t->post_ok('/api/v1/test_suites', form => {})->status_is(400);    #no name


$t->post_ok(
    '/api/v1/test_suites',
    form => {
        name => "testsuite",
        "settings[TEST]" => "val1",
        "settings[TEST2]" => "val1",
        description => "this is a new testsuite"
    })->status_is(200);
my $test_suite_id = $t->tx->res->json->{id};
my $event = OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create');
is_deeply(
    [sort keys %$event],
    ['description', 'id', 'name', 'settings', 'table'],
    'testsuite event was logged correctly'
);

$t->post_ok('/api/v1/test_suites', form => {name => "testsuite"})->status_is(400);    #already exists

$t->get_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'TestSuites' => [
            {
                'id' => $test_suite_id,
                'name' => 'testsuite',
                'description' => 'this is a new testsuite',
                'settings' => [
                    {
                        'key' => 'TEST',
                        'value' => 'val1'
                    },
                    {
                        'key' => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Add test_suite"
) || diag explain $t->tx->res->json;

$t->put_ok("/api/v1/test_suites/$test_suite_id", form => {name => "testsuite", "settings[TEST2]" => "val1"})
  ->status_is(200);

$t->get_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'TestSuites' => [
            {
                'id' => $test_suite_id,
                'name' => 'testsuite',
                'settings' => [
                    {
                        'key' => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Delete test_suite variable"
) || diag explain $t->tx->res->json;

$t->delete_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
$t->delete_ok("/api/v1/test_suites/$test_suite_id")->status_is(404);    #not found

# switch to operator (default client) and try some modifications
client($t);
$t->post_ok('/api/v1/test_suites', form => {name => "testsuite"})->status_is(403);
$t->put_ok("/api/v1/test_suites/$test_suite_id", form => {name => "testsuite", "settings[TEST2]" => "val1"})
  ->status_is(403);
$t->delete_ok("/api/v1/test_suites/$test_suite_id")->status_is(403);

done_testing();
