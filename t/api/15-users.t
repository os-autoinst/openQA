#!/usr/bin/env perl
# Copyright SUSE LLC
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

OpenQA::Test::Case->new->init_data(fixtures_glob => '0{1-jobs,3-users}.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $user_to_delete = $app->schema->resultset('Users')->find(99904);
$user_to_delete->update({is_operator => 1, is_admin => 1});
$t->delete_ok('/api/v1/user/99904')->status_is(200, 'admins can delete users');
$user_to_delete->discard_changes;
is $user_to_delete->is_operator, 0, 'operator role reverted after user deletion by admin';
is $user_to_delete->is_admin, 0, 'admin role reverted after user deletion by admin';
is_deeply
  OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'user_deleted'),
  {username => 'Demo'},
  'Delete was logged correctly';

$t->delete_ok('/api/v1/user/99999')->status_is(404, 'a non-existent user cannot be deleted');

subtest 'list users' => sub {
    my $res = $t->get_ok('/api/v1/users')->status_is(200, 'admin can list users')->tx->res->json;
    my $users = $res->{users};
    ok scalar @$users >= 4, 'all users returned in default query';
    my ($arthur) = grep { $_->{id} == 99901 } @$users;
    ok $arthur, 'arthur user found';
    is $arthur->{username}, 'arthur', 'arthur username matches';
    is $arthur->{nickname}, 'artie', 'arthur nickname matches';
    is $arthur->{fullname}, 'King Arthur', 'arthur fullname matches';
    is $arthur->{email}, 'arthur@example.com', 'arthur email matches';
    is $arthur->{is_operator}, 1, 'arthur is operator';
    is $arthur->{is_admin}, 1, 'arthur is admin';
    is $arthur->{deleted_at}, undef, 'arthur is not deleted';
    like $arthur->{t_created}, qr/^\d{4}-\d{2}-\d{2}/, 'arthur has formatted t_created';
    like $arthur->{t_updated}, qr/^\d{4}-\d{2}-\d{2}/, 'arthur has formatted t_updated';

    my ($demo) = grep { $_->{id} == 99904 } @$users;
    ok $demo, 'demo user found';
    is $demo->{username}, 'deleted-user-99904', 'demo username is anonymized';
    is $demo->{nickname}, undef, 'demo nickname is null';
    is $demo->{fullname}, undef, 'demo fullname is null';
    is $demo->{email}, undef, 'demo email is null';
    is $demo->{is_operator}, 0, 'demo is not operator';
    is $demo->{is_admin}, 0, 'demo is not admin';
    like $demo->{deleted_at}, qr/^\d{4}-\d{2}-\d{2}/, 'demo has formatted deleted_at';

    my $active_users
      = $t->get_ok('/api/v1/users?deleted=0')->status_is(200, 'list active users')->tx->res->json->{users};
    ok !(grep { defined $_->{deleted_at} } @$active_users), 'no deleted users in deleted=0 query';
    ok scalar(grep { $_->{id} == 99901 } @$active_users), 'active user 99901 present in deleted=0 query';
    ok !scalar(grep { $_->{id} == 99904 } @$active_users), 'deleted user 99904 absent from deleted=0 query';

    my $deleted_users
      = $t->get_ok('/api/v1/users?deleted=1')->status_is(200, 'list deleted users')->tx->res->json->{users};
    ok !(grep { !defined $_->{deleted_at} } @$deleted_users), 'only deleted users in deleted=1 query';
    ok scalar(grep { $_->{id} == 99904 } @$deleted_users), 'deleted user 99904 present in deleted=1 query';
    ok !scalar(grep { $_->{id} == 99901 } @$deleted_users), 'active user 99901 absent from deleted=1 query';

    my $paged_users
      = $t->get_ok('/api/v1/users?limit=2&offset=0')->status_is(200, 'list users with limit 2')->tx->res->json->{users};
    is scalar @$paged_users, 2, 'limit 2 returns 2 users';
    is $paged_users->[0]{id}, 1, 'first user in page is 1';
    is $paged_users->[1]{id}, 99901, 'second user in page is 99901';
    my $links = $t->tx->res->headers->links;
    ok $links->{first}, 'has first link in header';
    ok $links->{next}, 'has next link in header';

    my $offset_users = $t->get_ok('/api/v1/users?limit=2&offset=2')->status_is(200, 'list users with offset 2')
      ->tx->res->json->{users};
    is scalar @$offset_users, 2, 'offset 2 returns 2 users';
    is $offset_users->[0]{id}, 99902, 'first user in offset page is 99902';
    is $offset_users->[1]{id}, 99903, 'second user in offset page is 99903';
    $links = $t->tx->res->headers->links;
    ok $links->{prev}, 'has prev link in header';

    my $empty_page = $t->get_ok('/api/v1/users?limit=10&offset=100')->status_is(200, 'list users beyond range')
      ->tx->res->json->{users};
    is scalar @$empty_page, 0, 'offset beyond total returns empty array';

    $t->get_ok('/api/v1/users?limit=foo')->status_is(400, 'invalid limit rejected');
    $t->get_ok('/api/v1/users?offset=foo')->status_is(400, 'invalid offset rejected');
    $t->get_ok('/api/v1/users?deleted=2')->status_is(400, 'invalid deleted flag rejected');

    my $non_admin_t = Test::Mojo->new('OpenQA::WebAPI');
    $non_admin_t->ua(
        OpenQA::Client->new(apikey => 'LANCELOTKEY01', apisecret => 'MANYPEOPLEKNOW')->ioloop(Mojo::IOLoop->singleton));
    $non_admin_t->app($app);
    $non_admin_t->get_ok('/api/v1/users')->status_is(403, 'non-admin forbidden from listing users');

    my $unauth_t = Test::Mojo->new('OpenQA::WebAPI');
    $unauth_t->get_ok('/api/v1/users')->status_is(403, 'unauthenticated client forbidden from listing users');
};

$t->ua(OpenQA::Client->new(apikey => 'LANCELOTKEY01', apisecret => 'MANYPEOPLEKNOW')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->delete_ok('/api/v1/user/99904')->status_is(403, 'non-admins cannot delete users');

$t->post_ok('/api/v1/feature?version=42')->status_is(200, 'can set the feature version of current user');
is $app->schema->resultset('Users')->find(99902)->feature_version, 42, 'feature version was updated';

my $res = $t->post_ok('/api/v1/users/me/api_keys')->status_is(200, 'create api key')->tx->res->json;
ok $res->{key}, 'key returned';
ok $res->{secret}, 'secret returned and non-empty';
is $res->{comment}, '', 'comment is empty string when not provided on creation';
my $expected_year = time2str('%Y', time + ONE_YEAR, 'UTC');
like $res->{t_expiration}, qr/^$expected_year-/, 'default expiration is set to 1 year from now';
my $key1 = $res->{key};

my $new_key = $app->schema->resultset('ApiKeys')->find({key => $res->{key}});
ok $new_key, 'key found in DB';
is $new_key->user_id, 99902, 'key belongs to correct user';
is $new_key->comment, '', 'comment in DB is empty string when not provided';

subtest 'create_api_key with expiration' => sub {
    my $expiration_time = time + ONE_YEAR;
    my $expiration = time2str('%Y-%m-%d %H:%M:%S', $expiration_time, 'UTC');
    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => $expiration, comment => 'my bot key'})
      ->status_is(200, 'create api key with expiration and comment')->tx->res->json;
    ok $res->{key}, 'key returned';
    ok $res->{secret}, 'secret returned on key creation with expiration';
    is $res->{comment}, 'my bot key', 'comment matches submitted form value';
    my $expected_year = time2str('%Y', $expiration_time, 'UTC');
    like $res->{t_expiration}, qr/^$expected_year-/, 'expiration matches expected year';
};

subtest 'create_api_key with invalid expiration' => sub {
    $t->post_ok('/api/v1/users/me/api_keys' => form => {expiration => 'invalid'})
      ->status_is(400, 'invalid expiration rejected');
};

subtest 'create_api_key comment handling' => sub {
    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {comment => '   '})
      ->status_is(200, 'create api key with whitespace-only comment succeeds')->tx->res->json;
    is $res->{comment}, '', 'whitespace comment is normalized to empty string';

    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {comment => '  trimmed key  '})
      ->status_is(200, 'create api key with surrounding whitespace succeeds')->tx->res->json;
    is $res->{comment}, 'trimmed key', 'surrounding whitespace is trimmed';

    $res = $t->post_ok('/api/v1/users/me/api_keys' => form => {comment => '<escaped&untrusted>'})
      ->status_is(200, 'create api key with special characters succeeds')->tx->res->json;
    is $res->{comment}, '<escaped&untrusted>', 'special characters in comment preserved in JSON response';

    $t->post_ok('/api/v1/users/me/api_keys' => form => {comment => 'x' x 256})
      ->status_is(400, 'comment longer than 255 characters rejected');
};

subtest 'test list_api_keys' => sub {
    my $key2 = $res->{key};
    $res = $t->get_ok('/api/v1/users/me/api_keys')->status_is(200, 'list api keys')->tx->res->json;
    my $api_keys = $res->{keys};
    ok scalar @$api_keys >= 2, 'at least two keys found';
    my ($found_key1) = grep { $_->{key} eq $key1 } @$api_keys;
    ok $found_key1, "key $key1 found in list";
    is $found_key1->{comment}, '', 'comment is empty string in list when not provided';
    my ($found_key2) = grep { $_->{key} eq $key2 } @$api_keys;
    ok $found_key2, "key $key2 found in list";
    is $found_key2->{comment}, '<escaped&untrusted>', 'comment is present in listed key';
    ok !(grep { exists $_->{secret} } @$api_keys), 'secret is not present in any returned key';
};

subtest 'test delete_api_key' => sub {
    my $count_before = scalar @{$res->{keys}};
    $t->delete_ok("/api/v1/users/me/api_keys/$key1")->status_is(200, 'delete api key');
    $res = $t->get_ok('/api/v1/users/me/api_keys')->status_is(200)->tx->res->json;
    is scalar @{$res->{keys}}, $count_before - 1, 'one key less';
    ok !((grep { $_->{key} eq $key1 } @{$res->{keys}})), "key $key1 no longer in list";

    $t->delete_ok('/api/v1/users/me/api_keys/NONEXISTENT')->status_is(404, 'delete nonexistent key');
};

subtest 'test delete_self' => sub {
    my $user = $app->schema->resultset('Users')->find(99902);
    ok $user, 'user exists before deletion';
    $user->update({is_operator => 1, is_admin => 1});
    ok $user->api_keys->create({t_expiration => DateTime->now->add(years => 1)});
    ok $user->comments->create({text => 'test comment'}), 'comment created';
    ok $user->developer_sessions->create({job_id => 80000}), 'developer session created';
    $t->delete_ok('/api/v1/users/me')->status_is(200, 'user can delete own account');
    $user->discard_changes;
    ok $user->is_deleted, 'user is marked as deleted';
    is $user->username, 'deleted-user-99902', 'username anonymized';
    is $user->email, undef, 'email cleared';
    is $user->fullname, undef, 'fullname cleared';
    is $user->nickname, undef, 'nickname cleared';
    is $user->is_operator, 0, 'operator role reverted on self delete';
    is $user->is_admin, 0, 'admin role reverted on self delete';
    my $keys_after = $app->schema->resultset('ApiKeys')->search({user_id => 99902})->count;
    is $keys_after, 0, 'API keys deleted';
    is $user->comments->count, 1, 'comment preserved';
    is $user->developer_sessions->count, 1, 'developer session preserved';
    my $event = OpenQA::Test::Case::find_most_recent_event($app->schema, 'user_deleted');
    is $event->{username}, 'https://openid.camelot.uk/lancelot', 'delete event has original username';
};

subtest 'anonymize audit event data' => sub {
    my $user = $app->schema->resultset('Users')->find(99903);
    ok $user, 'user 99903 (percival) exists';
    is $user->is_operator, 1, 'operator role set before anonymize';
    is $user->is_admin, 0, 'admin role not set before anonymize';
    my $username = $user->username;
    my $event_data = "User $username performed an action";
    $user->audit_events->create(
        {
            event => 'job_created',
            event_data => $event_data,
        });
    my $audit_event = $user->audit_events->find({event => 'job_created'});
    is $audit_event->event_data, $event_data, 'audit event created with username in event_data';
    $user->anonymize;
    $user->discard_changes;
    $audit_event->discard_changes;
    is $user->is_operator, 0, 'operator role reverted on direct anonymize';
    is $user->is_admin, 0, 'admin role remains 0 on direct anonymize';
    is $audit_event->event_data, 'User deleted-user performed an action', 'event_data anonymized';
    is $audit_event->user_id, 99903, 'audit event association preserved';
};

done_testing();
