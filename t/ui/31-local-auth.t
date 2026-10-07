# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use DateTime;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '15';
use OpenQA::WebAPI::Auth::Local qw(hash_password);
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{auth}->{method} = 'Local';

$schema->resultset('Users')->create_user(
    'localuser',
    provider => 'Local',
    password => hash_password('correctpassword'),
);

my $deleted_user = $schema->resultset('Users')->create_user(
    'deletedlocal',
    provider => 'Local',
    password => hash_password('validpass'),
);
$deleted_user->update({deleted_at => DateTime->now});

$schema->resultset('Users')->create_user('nopasslocal', provider => 'Local',);

subtest 'auth_setup initialization hook' => sub {
    is OpenQA::WebAPI::Auth::Local::auth_setup($t->app), undef,
      'auth_setup executes as a clean no-op hook returning undef';
};

subtest 'login form presentation on GET request' => sub {
    $t->get_ok('/login')->status_is(200, 'login form renders with status 200 on GET')
      ->element_exists('form[action="/login"][method="post"]', 'form posting to login endpoint exists')
      ->element_exists('input[name="csrf_token"][type="hidden"]', 'hidden csrf token field exists')
      ->element_exists('input#username[name="username"]', 'username input field exists')
      ->element_exists('input#password[name="password"][type="password"]', 'password input field exists')
      ->element_exists('input[type="submit"], button[type="submit"]', 'submit button exists');
};

subtest 'rejection of invalid credentials on POST request' => sub {
    my @invalid_login_cases = (
        {desc => 'non-existent local user', form => {username => 'nosuchuser', password => 'somepass'}},
        {desc => 'existing local user with wrong password', form => {username => 'localuser', password => 'badpass'}},
        {desc => 'empty username', form => {username => '', password => 'somepass'}},
        {desc => 'empty password', form => {username => 'localuser', password => ''}},
        {desc => 'missing username field', form => {password => 'somepass'}},
        {desc => 'missing password field', form => {username => 'localuser'}},
        {
            desc => 'non-local provider user rejected by local auth',
            form => {username => 'arthur', password => 'somepass'}
        },
        {desc => 'deleted local user account', form => {username => 'deletedlocal', password => 'validpass'}},
        {desc => 'local user without password hash', form => {username => 'nopasslocal', password => 'anypass'}},
    );

    for my $case (@invalid_login_cases) {
        $t->post_ok('/login', form => $case->{form})->status_is(403, "status 403 returned for $case->{desc}")
          ->content_is('Invalid username or password', "standard error message returned for $case->{desc}");
    }
};

subtest 'successful login with valid credentials and redirection' => sub {
    my $csrf_token = $t->get_ok('/login')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted csrf token from login form';

    $t->post_ok(
        '/login' => {Referer => '/tests'},
        form => {username => 'localuser', password => 'correctpassword', csrf_token => $csrf_token}
    )->status_is(302, 'redirect status 302 returned after valid local credentials')
      ->header_is(Location => '/tests', 'redirects back to referer url after successful login');

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'authenticated test overview request succeeds')
          ->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as localuser/, 'user interface shows user is logged in as localuser';
};

subtest 'session termination on logout' => sub {
    $t->get_ok('/logout')->status_is(302, 'GET logout request returns redirect status')
      ->header_is(Location => '/', 'logout redirects to index page');

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'test overview accessible after logout')->tx->res->dom->at('#user-action')
          ->all_text);
    is $actions, 'Login', 'user interface shows unauthenticated login link after logout';

    $t->post_ok('/login', form => {username => 'localuser', password => 'correctpassword'})
      ->status_is(302, 'login succeeds again before delete logout check')
      ->header_is(Location => '/', 'login without referer redirects to index page');

    $t->delete_ok('/logout')->status_is(302, 'DELETE logout request returns redirect status')
      ->header_is(Location => '/', 'delete logout redirects to index page');

    $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'test overview accessible after delete logout')
          ->tx->res->dom->at('#user-action')->all_text);
    is $actions, 'Login', 'user interface shows unauthenticated login link after delete logout';
};

done_testing();
