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

$t->get_ok('/api/v1/machines')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Machines' => [
            {
                'backend' => 'qemu',
                'id' => 1001,
                'name' => '32bit',
                'settings' => [
                    {
                        'key' => 'QEMUCPU',
                        'value' => 'qemu32'
                    }]
            },
            {
                'backend' => 'qemu',
                'id' => 1002,
                'name' => '64bit',
                'settings' => [
                    {
                        'key' => 'QEMUCPU',
                        'value' => 'qemu64'
                    }]
            },
            {
                'backend' => 'qemu',
                'id' => 1008,
                'name' => 'Laptop_64',
                'settings' => [
                    {
                        'key' => 'LAPTOP',
                        'value' => '1'
                    },
                    {
                        'key' => 'QEMUCPU',
                        'value' => 'qemu64'
                    }]}]
    },
    "Initial machines"
) || diag explain $t->tx->res->json;


$t->post_ok('/api/v1/machines', form => {name => "testmachine"})->status_is(400)
  ->json_is('/error', 'Missing parameter: backend');
$t->post_ok('/api/v1/machines', form => {backend => "kde/usb"})->status_is(400)
  ->json_is('/error', 'Missing parameter: name');
$t->post_ok('/api/v1/machines', form => {})->status_is(400)->json_is('/error', 'Missing parameter: backend, name');

$t->post_ok('/api/v1/machines',
    form => {name => "testmachine", backend => "qemu", "settings[TEST]" => "val1", "settings[TEST2]" => "val1"})
  ->status_is(200);
my $machine_id = $t->tx->res->json->{id};
my $event = OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create');
is_deeply(
    [sort keys %$event],
    ['backend', 'description', 'id', 'name', 'settings', 'table'],
    'machine event was logged correctly'
);

$t->get_ok('/api/v1/machines', form => {name => "testmachine"})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{id}, $machine_id);

$t->post_ok('/api/v1/machines',
    form => {name => "testmachineQ", backend => "qemu", "settings[TEST]" => "'v'al1", "settings[TEST2]" => "va'l\'1"})
  ->status_is(200);
$t->get_ok('/api/v1/machines', form => {name => "testmachineQ"})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");
is($t->tx->res->json->{Machines}->[0]->{settings}->[1]->{value}, "va'l\'1");

$t->post_ok('/api/v1/machines', form => {name => "testmachineZ", backend => "qemu", "settings[TE'S\'T]" => "'v'al1"})
  ->status_is(200);
$t->get_ok('/api/v1/machines', form => {name => "testmachineQ"})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{key}, "TEST");
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");

$t->post_ok('/api/v1/machines', form => {name => "testmachine", backend => "qemu"})->status_is(400);    #already exists

$t->get_ok("/api/v1/machines/$machine_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Machines' => [
            {
                'backend' => 'qemu',
                'id' => $machine_id,
                'name' => 'testmachine',
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
    "Add machine"
) || diag explain $t->tx->res->json;

$t->put_ok("/api/v1/machines/$machine_id",
    form => {name => "testmachine", backend => "qemu", "settings[TEST2]" => "val1"})->status_is(200);

$t->get_ok("/api/v1/machines/$machine_id")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'Machines' => [
            {
                'backend' => 'qemu',
                'id' => $machine_id,
                'name' => 'testmachine',
                'settings' => [
                    {
                        'key' => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Delete machine variable"
) || diag explain $t->tx->res->json;

$t->delete_ok("/api/v1/machines/$machine_id")->status_is(200);
$t->delete_ok("/api/v1/machines/$machine_id")->status_is(404);    #not found

subtest 'trim whitespace characters' => sub {
    $t->post_ok(
        '/api/v1/machines',
        form => {
            name => " create_with_space ",
            backend => " qemu ",
            "settings[ TEST ]" => " test value  ",
            "settings[TEST2  ]" => " test value2  ",
        })->status_is(200);
    my $id = $t->tx->res->json->{id};
    $t->get_ok("/api/v1/machines/$id")->status_is(200);
    $t->json_is(
        '' => {
            'Machines' => [
                {
                    'backend' => 'qemu',
                    'id' => $id,
                    'name' => 'create_with_space',
                    'settings' => [
                        {
                            'key' => 'TEST',
                            'value' => 'test value'
                        },
                        {
                            'key' => 'TEST2',
                            'value' => 'test value2'
                        }]}]
        },
        'trim whitespace characters when create table'
    )->or(sub { diag explain $t->tx->res->json });

    $t->put_ok(
        "/api/v1/machines/$id",
        form => {
            name => "  update_with_space ",
            backend => "qemu ",
            "settings[ TEST ]" => " new test value  ",
            "settings[ TEST3]" => "  new test value3 ",
        })->status_is(200);
    $t->get_ok("/api/v1/machines/$id")->status_is(200);
    $t->json_is(
        '' => {
            'Machines' => [
                {
                    'backend' => 'qemu',
                    'id' => $id,
                    'name' => 'update_with_space',
                    'settings' => [
                        {
                            'key' => 'TEST',
                            'value' => 'new test value'
                        },
                        {
                            'key' => 'TEST3',
                            'value' => 'new test value3'
                        }]}]
        },
        'trim whitespace characters when update table'
    )->or(sub { diag explain $t->tx->res->json });
};

# switch to operator (default client) and try some modifications
client($t);
$t->post_ok('/api/v1/machines',
    form => {name => "testmachine", backend => "qemu", "settings[TEST]" => "val1", "settings[TEST2]" => "val1"})
  ->status_is(403);
$t->put_ok("/api/v1/machines/$machine_id",
    form => {name => "testmachine", backend => "qemu", "settings[TEST2]" => "val1"})->status_is(403);
$t->delete_ok("/api/v1/machines/$machine_id")->status_is(403);

done_testing();
