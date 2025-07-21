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
    'Initial machines'
) || always_explain $t->tx->res->json;


$t->post_ok('/api/v1/machines', json => {name => 'testmachine'})->status_is(400)
  ->json_is('/error', 'Missing parameter: backend');
$t->post_ok('/api/v1/machines', json => {backend => 'kde/usb'})->status_is(400)
  ->json_is('/error', 'Missing parameter: name');
$t->post_ok('/api/v1/machines', json => {})->status_is(400)->json_is('/error', 'Missing parameter: backend, name');

$t->post_ok('/api/v1/machines',
    json => {name => 'testmachine', backend => 'qemu', 'settings' => {'TEST' => 'val1', 'TEST2' => 'val1'}})
  ->status_is(200);
my $machine_id = $t->tx->res->json->{id};
my $event = OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create');
is_deeply(
    [sort keys %$event],
    ['backend', 'description', 'id', 'name', 'settings', 'table'],
    'machine event was logged correctly'
);

$t->get_ok('/api/v1/machines', form => {name => 'testmachine'})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{id}, $machine_id);

$t->post_ok('/api/v1/machines',
    json => {name => 'testmachineQ', backend => 'qemu', 'settings' => {'TEST' => "'v'al1", 'TEST2' => "va'l\'1"}})
  ->status_is(200);
$t->get_ok('/api/v1/machines', form => {name => 'testmachineQ'})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");
is($t->tx->res->json->{Machines}->[0]->{settings}->[1]->{value}, "va'l\'1");

$t->post_ok('/api/v1/machines', json => {name => 'testmachineZ', backend => 'qemu', 'settings' => {'TEST' => "'v'al1"}})
  ->status_is(200);
$t->get_ok('/api/v1/machines', form => {name => 'testmachineQ'})->status_is(200);
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{key}, 'TEST');
is($t->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");

$t->post_ok('/api/v1/machines', json => {name => 'testmachine', backend => 'qemu'})->status_is(400);    #already exists

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
    'Add machine'
) || always_explain $t->tx->res->json;

$t->put_ok("/api/v1/machines/$machine_id",
    json => {name => 'testmachine', backend => 'qemu', settings => {'TEST2' => 'val1'}})->status_is(200);

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
    'Delete machine variable'
) || always_explain $t->tx->res->json;

$t->put_ok("/api/v1/machines/$machine_id", json => {name => 'testmachine', 'settings' => {'TEST2' => 'val0'}})
  ->status_is(400)->json_is('/error', 'Missing parameter: backend');

$t->put_ok("/api/v1/machines/$machine_id", => {'Content-Type' => 'application/json'} => '{BROKEN JSON')->status_is(400)
  ->json_like('/error', qr/expected, at character offset/);

$t->put_ok("/api/v1/machines/$machine_id", => {'Content-Type' => 'text/html'})->status_is(400)
  ->json_like('/error', qr/Invalid request Content-Type/);

$t->put_ok("/api/v1/machines/$machine_id",
    json => {name => 'testmachine', backend => 'qemu', 'settings' => {"TEST2'" => 'val2'}})->status_is(400)
  ->json_like('/error', qr(Invalid characters <b>&#39;</b> in settings key <b>TEST2&#39;</b>));

$t->put_ok("/api/v1/machines/$machine_id",
    json => {name => 'testmachine', backend => 'qemu', 'settings' => {'TEST2' => 'val2'}})->status_is(200);

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
                        'value' => 'val2'
                    }]}]
    },
    'Update settings via JSON request'
) || always_explain $t->tx->res->json;

$t->delete_ok("/api/v1/machines/$machine_id")->status_is(200);
$t->delete_ok("/api/v1/machines/$machine_id")->status_is(404);    #not found

subtest 'trim whitespace characters' => sub {
    $t->post_ok(
        '/api/v1/machines',
        json => {
            name => ' create_with_space ',
            backend => ' qemu ',
            settings => {
                ' TEST ' => ' test value  ',
                'TEST2  ' => ' test value2  '
            }})->status_is(200);
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
    )->or(sub { always_explain $t->tx->res->json });

    $t->put_ok(
        "/api/v1/machines/$id",
        json => {
            name => '  update_with_space ',
            backend => 'qemu ',
            settings => {
                ' TEST ' => ' new test value  ',
                ' TEST3' => '  new test value3 '
            }})->status_is(200);
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
    )->or(sub { always_explain $t->tx->res->json });
};

# switch to operator (default client) and try some modifications
client($t);
$t->post_ok('/api/v1/machines',
    json => {name => 'testmachine', backend => 'qemu', 'settings' => {'TEST' => 'val1', 'TEST2' => 'val1'}})
  ->status_is(403);
$t->put_ok("/api/v1/machines/$machine_id",
    json => {name => 'testmachine', backend => 'qemu', 'settings' => {'TEST2' => 'val1'}})->status_is(403);
$t->delete_ok("/api/v1/machines/$machine_id")->status_is(403);

subtest 'server-side limit has precedence over user-specified limit' => sub {
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limits->{generic_max_limit} = 5;
    $limits->{generic_default_limit} = 2;

    $t->get_ok('/api/v1/machines?limit=10', 'query with exceeding user-specified limit for machines')->status_is(200);
    my $machines = $t->tx->res->json->{Machines};
    is ref $machines, 'ARRAY', 'data returned (1)'
      and is scalar @$machines, 5, 'maximum limit for machines is effective';

    $t->get_ok('/api/v1/machines?limit=3', 'query with exceeding user-specified limit for machines')->status_is(200);
    $machines = $t->tx->res->json->{Machines};
    is ref $machines, 'ARRAY', 'data returned (2)'
      and is scalar @$machines, 3, 'user limit for machines is effective';

    $t->get_ok('/api/v1/machines', 'query with (low) default limit for machines')->status_is(200);
    $machines = $t->tx->res->json->{Machines};
    is ref $machines, 'ARRAY', 'data returned (3)'
      and is scalar @$machines, 2, 'default limit for machines is effective';
};

subtest 'server-side limit with pagination' => sub {
    subtest 'input validation' => sub {
        $t->get_ok('/api/v1/machines?limit=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (limit invalid)'});
        $t->get_ok('/api/v1/machines?offset=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (offset invalid)'});
    };

    subtest 'navigation with high limit' => sub {
        my $links;

        subtest 'first page' => sub {
            $t->get_ok('/api/v1/machines?limit=5')->status_is(200)->json_has('/Machines/4')->json_hasnt('/Machines/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };

        subtest 'second page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_has('/Machines/0')->json_hasnt('/Machines/1');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok !$links->{next}, 'no next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'first page (prev link)' => sub {
            $t->get_ok($links->{prev}{link})->status_is(200)->json_has('/Machines/4')->json_hasnt('/Machines/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };

        subtest 'first page (first link)' => sub {
            $t->get_ok($links->{first}{link})->status_is(200)->json_has('/Machines/4')->json_hasnt('/Machines/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };
    };

    subtest 'navigation with low limit' => sub {
        my $links;
        subtest 'first page' => sub {
            $t->get_ok('/api/v1/machines?limit=2')->status_is(200)->json_has('/Machines/1')->json_hasnt('/Machines/2')
              ->json_like('/Machines/0/name', qr/32bit/)->json_like('/Machines/1/name', qr/64bit/);
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };

        subtest 'second page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_has('/Machines/1')->json_hasnt('/Machines/2')
              ->json_like('/Machines/0/name', qr/Laptop_64/)->json_like('/Machines/1/name', qr/testmachineQ/);
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'third page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_has('/Machines/1')->json_hasnt('/Machines/2');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok !$links->{next}, 'no next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'first page (first link)' => sub {
            $t->get_ok($links->{first}{link})->status_is(200)->json_has('/Machines/1')->json_hasnt('/Machines/2')
              ->json_like('/Machines/0/name', qr/32bit/)->json_like('/Machines/1/name', qr/64bit/);
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };
    };
};

done_testing();
