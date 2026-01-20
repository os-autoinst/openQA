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
is $res->{t_expiration}, undef, 'default expiration is undef (never)';

my $new_key = $app->schema->resultset('ApiKeys')->find({key => $res->{key}});
ok $new_key, 'key found in DB';
is $new_key->user_id, 99902, 'key belongs to correct user';

subtest 'create_api_key with expiration' => sub {
    my $expiration = time2str('%Y-%m-%d %H:%M:%S', time + ONE_YEAR, 'UTC');
    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => $expiration})
      ->status_is(200, 'create api key with expiration')->tx->res->json;
    ok $res->{key}, 'key returned';
    like $res->{t_expiration}, qr/^[0-9]+/, 'expiration looks like date';
};

subtest 'create_api_key with invalid expiration' => sub {
    $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => 'invalid'})
      ->status_is(400, 'invalid expiration rejected');
};

done_testing();
