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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::URL;
use Mojo::Util qw(encode hmac_sha1_sum);
use OpenQA::Test::Case;
use OpenQA::Client;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# we don't want to *actually* delete any assets when we're testing
# whether we're allowed to or not, so let's mock that out
my $mock_asset_remove_callcount = 0;
my $mock_asset                  = Test::MockModule->new('OpenQA::Schema::Result::Assets');
$mock_asset->mock(remove_from_disk => sub { $mock_asset_remove_callcount++; return 1; });

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

subtest 'access limiting for non authenticated users' => sub() {
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->get_ok('/api/v1/products')->status_is(200);
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($t->tx->res->code, 403, 'delete forbidden');
    is_deeply(
        $t->tx->res->json,
        {
            error        => 'no api key',
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

subtest 'access limiting for authenticated users but not operators nor admins' => sub() {
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

subtest 'access limiting for authenticated operators but not admins' => sub() {
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

subtest 'access granted for admins' => sub() {
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

subtest 'wrong api key - expired' => sub() {
    $t->ua->apikey('EXPIREDKEY01');
    $t->ua->apisecret('WHOCARESAFTERALL');
    $t->get_ok('/api/v1/jobs')->status_is(200);
    $t->post_ok('/api/v1/products/1')->status_is(403);
    is($t->tx->res->json->{error}, 'api key expired', 'key expired error');
    $t->delete_ok('/api/v1/assets/1')->status_is(403);
    is($t->tx->res->json->{error},   'api key expired', 'key expired error');
    is($mock_asset_remove_callcount, 0,                 'asset deletion function was not called');
};

subtest 'wrong api key - not maching key + secret' => sub() {
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

subtest 'wrong api key - replay attack' => sub() {
    $t->ua->apikey('ARTHURKEY01');
    $t->ua->apisecret('EXCALIBUR');
    $t->ua->unsubscribe('start');
    $t->ua->on(
        start => sub {
            my ($self, $tx) = @_;

            my $timestamp = 0;
            my %headers   = (
                'X-API-Key'       => $self->apikey,
                'X-API-Microtime' => $timestamp,
                'X-API-Hash'      => hmac_sha1_sum($self->_path_query($tx) . $timestamp, $self->apisecret),
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

done_testing();
