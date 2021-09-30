#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use Mojo::URL;
use Mojo::Util qw(encode hmac_sha1_sum);
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';

OpenQA::Test::Case->new->init_data((fixtures_glob => '01-jobs.pl 03-users.pl'));
my $t = Test::Mojo->new('OpenQA::WebAPI');

# we don't want to *actually* delete any assets when we're testing
# whether we're allowed to or not, so let's mock that out
my $mock_asset_remove_callcount = 0;
my $mock_asset = Test::MockModule->new('OpenQA::Schema::Result::Assets');
$mock_asset->redefine(remove_from_disk => sub { $mock_asset_remove_callcount++; return 1; });

subtest 'authentication routes for plugins' => sub {
    my $public = $t->app->routes->find('api_public');
    ok $public, 'api_pubic route found';
    $public->put('/public_plugin' => sub { shift->render(text => 'API public plugin works!') });
    my $ensure_user = $t->app->routes->find('api_ensure_user');
    ok $ensure_user, 'api_ensure_user route found';
    $ensure_user->put('/user_plugin' => sub { shift->render(text => 'API user plugin works!') });
    my $ensure_admin = $t->app->routes->find('api_ensure_admin');
    ok $ensure_admin, 'api_ensure_admin route found';
    $ensure_admin->put('/admin_plugin' => sub { shift->render(text => 'API admin plugin works!') });
    my $ensure_operator = $t->app->routes->find('api_ensure_operator');
    ok $ensure_operator, 'api_ensure_operator route found';
    $ensure_operator->put('/operator_plugin' => sub { shift->render(text => 'API operator plugin works!') });
};

client($t, apikey => undef, apisecret => undef);

subtest 'access limiting for non authenticated users' => sub {
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(200);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($t->tx->res->code, 403, 'delete forbidden');
    is_deeply(
        $t->tx->res->json,
        {
            error => 'no api key',
            error_status => 403,
        },
        'error returned as JSON'
    );
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
    $t->put_ok('/api/v1/public_plugin')->status_is(200)->content_is('API public plugin works!');
    $t->put_ok('/api/v1/user_plugin')->status_is(403);
    $t->put_ok('/api/v1/admin_plugin')->status_is(403);
    $t->put_ok('/api/v1/operator_plugin')->status_is(403);
};

client($t);

subtest 'access limiting for authenticated users but not operators nor admins' => sub {
    $t->ua->apikey('LANCELOTKEY01');
    $t->ua->apisecret('MANYPEOPLEKNOW');
    $t->get_ok('/api/v1/jobs')->status_is(200, 'accessible (public)');
    $t->post_ok('/api/v1/assets')->status_is(403, 'restricted (operator and admin only)');
    $t->delete_ok('/api/v1/assets/1')->status_is(403, 'restricted (admin only)');
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
    $t->put_ok('/api/v1/public_plugin')->status_is(200)->content_is('API public plugin works!');
    $t->put_ok('/api/v1/user_plugin')->status_is(200)->content_is('API user plugin works!');
    $t->put_ok('/api/v1/admin_plugin')->status_is(403);
    $t->put_ok('/api/v1/operator_plugin')->status_is(403);
};

subtest 'access limiting for authenticated operators but not admins' => sub {
    $t->ua->apikey('PERCIVALKEY01');
    $t->ua->apisecret('PERCIVALSECRET01');
    $t->get_ok('/api/v1/jobs')->status_is(200, 'accessible (public)');
    $t->post_ok('/api/v1/jobs/99927/set_done')->status_is(200, 'accessible (operator and admin only)');
    $t->delete_ok('/api/v1/assets/1')->status_is(403, 'restricted (admin only)');
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
    $t->put_ok('/api/v1/public_plugin')->status_is(200)->content_is('API public plugin works!');
    $t->put_ok('/api/v1/user_plugin')->status_is(200)->content_is('API user plugin works!');
    $t->put_ok('/api/v1/admin_plugin')->status_is(403);
    $t->put_ok('/api/v1/operator_plugin')->status_is(200)->content_is('API operator plugin works!');
};

subtest 'access granted for admins' => sub {
    $t->ua->apikey('ARTHURKEY01');
    $t->ua->apisecret('EXCALIBUR');
    $t->get_ok('/api/v1/jobs')->status_is(200, 'accessible (public)');
    $t->post_ok('/api/v1/jobs/99927/set_done')->status_is(200, 'accessible (operator and admin only)');
    $t->delete_ok('/api/v1/assets/1')->status_is(200, 'accessible (admin only)');
    is($mock_asset_remove_callcount, 1, 'asset deletion function was called');
    # reset the call count
    $mock_asset_remove_callcount = 0;
    $t->put_ok('/api/v1/public_plugin')->status_is(200)->content_is('API public plugin works!');
    $t->put_ok('/api/v1/user_plugin')->status_is(200)->content_is('API user plugin works!');
    $t->put_ok('/api/v1/admin_plugin')->status_is(200)->content_is('API admin plugin works!');
    $t->put_ok('/api/v1/operator_plugin')->status_is(200)->content_is('API operator plugin works!');
};

subtest 'wrong api key - expired' => sub {
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('WHOCARESAFTERALL');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->post_ok('/api/v1/products/1')->status_is(403);
    is($t->tx->res->json->{error}, 'api key expired', 'key expired error');
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($t->tx->res->json->{error}, 'api key expired', 'key expired error');
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
};

subtest 'wrong api key - not maching key + secret' => sub {
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('INVALIDSECRET');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->post_ok('/api/v1/products/1')->status_is(403);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
};

subtest 'no key, no secret' => sub {
    $t->ua->apikey('NOTEXISTINGKEY');
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
};

subtest 'wrong api key - replay attack' => sub {
    $t->ua->apikey('ARTHURKEY01');
    $t->ua->apisecret('EXCALIBUR');
    $t->ua->unsubscribe('start');
    $t->ua->on(
        start => sub ($ua, $tx) {

            my $timestamp = 0;
            my %headers = (
                'X-API-Key' => $ua->apikey,
                'X-API-Microtime' => $timestamp,
                'X-API-Hash' => hmac_sha1_sum($ua->_path_query($tx) . $timestamp, $ua->apisecret),
            );

            foreach my $key (keys %headers) {
                $tx->req->headers->header($key, $headers{$key});
            }
        });
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->post_ok('/api/v1/products/1')->status_is(403)
      ->json_is('/error' => 'timestamp mismatch', 'timestamp mismatch error');
    $t->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is('/error' => 'timestamp mismatch', 'timestamp mismatch error');
    is($mock_asset_remove_callcount, 0, 'asset deletion function was not called');
};

subtest 'personal access token' => sub {
    my $userinfo = sub ($t, $userinfo) {
        $t->ua->once(start => sub ($ua, $tx) { $tx->req->url->userinfo($userinfo) });
        return $t;
    };

    # No access token
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->delete_ok('/api/v1/assets/1')->status_is(403)->json_is({error => 'no api key'});

    # Valid access token
    $t->$userinfo('artie:ARTHURKEY01:EXCALIBUR')->delete_ok('/api/v1/assets/1')->status_is(404);

    # Valid access token (OpenID user)
    $t->$userinfo('lance:LANCELOTKEY01:MANYPEOPLEKNOW')->post_ok('/api/v1/feature' => form => {version => 100})
      ->status_is(200);

    # Invalid access token
    $t->$userinfo('invalid:invalid')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'invalid personal access token'});

    # Invalid username
    $t->$userinfo('invalid:ARTHURKEY01:EXCALIBUR')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'invalid personal access token'});

    # Invalid key
    $t->$userinfo('artie:INVALID:EXCALIBUR')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'invalid personal access token'});

    # Invalid secret
    $t->$userinfo('artie:ARTHURKEY01:INVALID')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'invalid personal access token'});

    # Invalid secret (OpenID user)
    $t->$userinfo('lance:LANCELOTKEY01:INVALIDTOO')->post_ok('/api/v1/feature' => form => {version => 100})
      ->status_is(403)->json_is({error => 'invalid personal access token'});

    # Valid access token (again)
    $t->$userinfo('artie:ARTHURKEY01:EXCALIBUR')->delete_ok('/api/v1/assets/1')->status_is(404);
};

subtest 'personal access token (with reverse proxy)' => sub {
    my $forwarded = sub ($t, $userinfo, $for, $proto) {
        $t->ua->once(
            start => sub ($ua, $tx) {
                $tx->req->url->userinfo($userinfo);
                $tx->req->headers->header('X-Forwarded-For' => $for);
                $tx->req->headers->header('X-Forwarded-Proto' => $proto);
            });
        return $t;
    };

    # Not HTTPS or localhost
    local $ENV{MOJO_REVERSE_PROXY} = 1;
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->$forwarded('artie:ARTHURKEY01:EXCALIBUR', '192.168.2.1', 'http')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'personal access token can only be used via HTTPS or from localhost'});

    # HTTPS
    $t->$forwarded('artie:ARTHURKEY01:EXCALIBUR', '192.168.2.1', 'https')->delete_ok('/api/v1/assets/1')
      ->status_is(404);

    # localhost
    $t->$forwarded('artie:ARTHURKEY01:EXCALIBUR', '127.0.0.1', 'http')->delete_ok('/api/v1/assets/1')->status_is(404);

    # localhost (IPv6)
    $t->$forwarded('artie:ARTHURKEY01:EXCALIBUR', '::1', 'http')->delete_ok('/api/v1/assets/1')->status_is(404);

    # HTTPS and localhost
    $t->$forwarded('artie:ARTHURKEY01:EXCALIBUR', '127.0.0.1', 'https')->delete_ok('/api/v1/assets/1')->status_is(404);

    # HTTPS but invalid key
    $t->$forwarded('artie:INVALID:EXCALIBUR', '192.168.2.1', 'https')->delete_ok('/api/v1/assets/1')->status_is(403)
      ->json_is({error => 'invalid personal access token'});
};

done_testing();
