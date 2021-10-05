# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'authentication routes for plugins' => sub {
    my $ensure_admin = $t->app->routes->find('ensure_admin');
    ok $ensure_admin, 'ensure_admin route found';
    $ensure_admin->get('/admin_plugin' => {text => 'Admin plugin works!'});
    my $ensure_operator = $t->app->routes->find('ensure_operator');
    ok $ensure_operator, 'ensure_operator route found';
    $ensure_operator->get('/operator_plugin' => {text => 'Operator plugin works!'});
};

#
# No login, no user-info and no api_keys
my $res = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
is($res, 'Login', 'no-one logged in');
$t->get_ok('/api_keys')->status_is(302);

#
# So let's log in as an unpriviledged user
$test_case->login($t, 'https://openid.camelot.uk/lancelot');
# ...who should see a logout option but no link to API keys
$res = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
like($res, qr/Logged in as lance Operators Menu.*Logout/, 'lance is logged in');
$t->get_ok('/api_keys')->status_is(403);

#
# Unprivileged users can't access the plugins either
$t->get_ok('/admin/admin_plugin')->status_is(403);
$t->get_ok('/admin/operator_plugin')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
$res = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
is($res, 'Login', 'no-one logged in');

#
# Try creating new user by logging in
$test_case->login($t, 'morgana');
# ...who should see a logout option but no link to API keys
$res = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
like($res, qr/Logged in as morgana Operators Menu.*API help Changelog Logout/, 'morgana as no api keys');
$t->get_ok('/api_keys')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
$res = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
is($res, 'Login', 'no-one logged in');

#
# And log in as operator
$test_case->login($t, 'percival');
my $actions = OpenQA::Test::Case::trim_whitespace(
    $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text);
like(
    $actions,
    qr/Logged in as perci Operators Menu.*Manage API keys API help Changelog Logout/,
    'perci has operator links'
);
unlike($actions, qr/Administrators Menu/, 'perci has no admin links');
$t->get_ok('/api_keys')->status_is(200);

#
# Operator user can access the operator plugin but not the admin plugin
$t->get_ok('/admin/admin_plugin')->status_is(403);
$t->get_ok('/admin/operator_plugin')->status_is(200)->content_is('Operator plugin works!');

#
# Admin user can access everything
$t->app->schema->resultset('Users')->search({username => 'percival'})->next->update({is_admin => 1});
$t->get_ok('/admin/operator_plugin')->status_is(200)->content_is('Operator plugin works!');
$t->get_ok('/admin/admin_plugin')->status_is(200)->content_is('Admin plugin works!');

done_testing();
