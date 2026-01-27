#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Date::Format 'time2str';
use Time::Seconds;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Client;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->delete_ok('/api/v1/user/99904')->status_is(200, 'admins can delete users');
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'user_deleted'),
    {username => 'Demo'},
    'Delete was logged correctly'
);

$t->delete_ok('/api/v1/user/99999')->status_is(404, 'a non-existent user cannot be deleted');

$t->ua(OpenQA::Client->new(apikey => 'LANCELOTKEY01', apisecret => 'MANYPEOPLEKNOW')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->delete_ok('/api/v1/user/99904')->status_is(403, 'non-admins cannot delete users');

$t->post_ok('/api/v1/feature?version=42')->status_is(200, 'can set the feature version of current user');
is $app->schema->resultset('Users')->find(99902)->feature_version, 42, 'feature version was updated';

my $res = $t->post_ok('/api/v1/users/me/api_keys')->status_is(200, 'create api key')->tx->res->json;
ok $res->{key}, 'key returned';
my $expected_year = time2str('%Y', time + ONE_YEAR, 'UTC');
like $res->{t_expiration}, qr/^$expected_year-/, 'default expiration is set to 1 year from now';
my $key1 = $res->{key};

my $new_key = $app->schema->resultset('ApiKeys')->find({key => $res->{key}});
ok $new_key, 'key found in DB';
is $new_key->user_id, 99902, 'key belongs to correct user';

subtest 'create_api_key with expiration' => sub {
    my $expiration_time = time + ONE_YEAR;
    my $expiration = time2str('%Y-%m-%d %H:%M:%S', $expiration_time, 'UTC');
    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => $expiration})
      ->status_is(200, 'create api key with expiration')->tx->res->json;
    ok $res->{key}, 'key returned';
    my $expected_year = time2str('%Y', $expiration_time, 'UTC');
    like $res->{t_expiration}, qr/^$expected_year-/, 'expiration matches expected year';
};

subtest 'create_api_key with invalid expiration' => sub {
    $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => 'invalid'})
      ->status_is(400, 'invalid expiration rejected');
};

subtest 'test list_api_keys' => sub {
    my $key2 = $res->{key};
    $res = $t->get_ok('/api/v1/users/me/api_keys')->status_is(200, 'list api keys')->tx->res->json;
    my $api_keys = $res->{keys};
    ok scalar @$api_keys >= 2, 'at least two keys found';
    ok((grep { $_->{key} eq $key1 } @$api_keys), "key $key1 found in list");
    ok((grep { $_->{key} eq $key2 } @$api_keys), "key $key2 found in list");
    ok !exists $api_keys->[0]{secret}, 'secret is not returned in list';
};

subtest 'test delete_api_key' => sub {
    my $count_before = scalar @{$res->{keys}};
    $t->delete_ok("/api/v1/users/me/api_keys/$key1")->status_is(200, 'delete api key');
    $res = $t->get_ok('/api/v1/users/me/api_keys')->status_is(200)->tx->res->json;
    is scalar @{$res->{keys}}, $count_before - 1, 'one key less';
    ok !((grep { $_->{key} eq $key1 } @{$res->{keys}})), "key $key1 no longer in list";

    $t->delete_ok("/api/v1/users/me/api_keys/NONEXISTENT")->status_is(404, 'delete nonexistent key');
};

done_testing();
