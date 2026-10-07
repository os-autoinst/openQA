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

subtest 'registration form presentation and navigation link' => sub {
    $t->get_ok('/register')->status_is(200, 'registration form renders with status 200 on GET')
      ->element_exists('form[action="/register"][method="post"]', 'form posting to register endpoint exists')
      ->element_exists('input[name="csrf_token"][type="hidden"]', 'hidden csrf token field exists')
      ->element_exists('input#username[name="username"]', 'username input field exists')
      ->element_exists('input#password[name="password"][type="password"]', 'password input field exists')
      ->element_exists('input[type="submit"], button[type="submit"]', 'submit button exists');

    $t->get_ok('/tests')->status_is(200, 'tests page accessible when logged out')
      ->element_exists('a[href="/register"]', 'register link exists in navbar for local auth when logged out');
};

subtest 'registration disabled when auth method is not local' => sub {
    $t->app->config->{auth}->{method} = 'Fake';

    $t->get_ok('/register')->status_is(403, 'GET register forbidden when auth method is not Local');
    $t->post_ok('/register', form => {username => 'someuser', password => 'password123'})
      ->status_is(403, 'POST register forbidden when auth method is not Local');
    $t->get_ok('/tests')->status_is(200, 'tests page accessible with non-local auth')
      ->element_exists_not('a[href="/register"]', 'register link hidden when auth method is not Local');

    $t->app->config->{auth}->{method} = 'Local';
};

subtest 'rejection of invalid registration policy and duplicate username' => sub {
    my @invalid_registration_cases = (
        {desc => 'empty username', form => {username => '', password => 'validpass123'}, err => qr/Invalid username/},
        {desc => 'missing username', form => {password => 'validpass123'}, err => qr/Invalid username/},
        {
            desc => 'too short username',
            form => {username => 'ab', password => 'validpass123'},
            err => qr/Invalid username/
        },
        {
            desc => 'too long username',
            form => {username => 'a' x 65, password => 'validpass123'},
            err => qr/Invalid username/
        },
        {
            desc => 'invalid character in username',
            form => {username => 'user$name', password => 'validpass123'},
            err => qr/Invalid username/
        },
        {
            desc => 'space in username',
            form => {username => 'user name', password => 'validpass123'},
            err => qr/Invalid username/
        },
        {
            desc => 'empty password',
            form => {username => 'validuser', password => ''},
            err => qr/Password must be at least 8 characters/
        },
        {
            desc => 'missing password',
            form => {username => 'validuser'},
            err => qr/Password must be at least 8 characters/
        },
        {
            desc => 'too short password',
            form => {username => 'validuser', password => 'short'},
            err => qr/Password must be at least 8 characters/
        },
        {
            desc => 'whitespace-only password',
            form => {username => 'validuser', password => '        '},
            err => qr/Password cannot be whitespace only/
        },
        {
            desc => 'password identical to username',
            form => {username => 'matchinguser', password => 'matchinguser'},
            err => qr/Password cannot match username/
        },
        {
            desc => 'duplicate username under local provider',
            form => {username => 'localuser', password => 'validpass123'},
            err => qr/Username already taken/
        },
        {
            desc => 'duplicate username under non-local provider',
            form => {username => 'arthur', password => 'validpass123'},
            err => qr/Username already taken/
        },
    );

    for my $case (@invalid_registration_cases) {
        $t->post_ok('/register', form => $case->{form})->status_is(403, "status 403 returned for $case->{desc}")
          ->content_like($case->{err}, "expected policy error message for $case->{desc}");
    }
};

subtest 'successful registration of first user as admin and subsequent user as non-admin' => sub {
    $schema->resultset('Users')->search({is_admin => 1})->update({is_admin => 0});

    $t->post_ok('/register', form => {username => 'firstadmin', password => 'secureadminpass'})
      ->status_is(302, 'first user registration returns redirect status')
      ->header_is(Location => '/login', 'successful registration redirects to login');

    my $first_user = $schema->resultset('Users')->find({username => 'firstadmin'});
    ok $first_user, 'first registered user exists in database';
    is $first_user->is_admin, 1, 'first registered user is granted admin privileges';
    is $first_user->is_operator, 1, 'first registered user is granted operator privileges';
    is $schema->resultset('AuditEvents')->search({user_id => $first_user->id, event => 'user_register'})->count, 1,
      'audit event user_register recorded for first user';

    $t->post_ok('/register', form => {username => 'regularuser', password => 'regularpass123'})
      ->status_is(302, 'subsequent user registration returns redirect status')
      ->header_is(Location => '/login', 'subsequent registration redirects to login');

    my $reg_user = $schema->resultset('Users')->find({username => 'regularuser'});
    ok $reg_user, 'subsequent registered user exists in database';
    is $reg_user->is_admin, 0, 'subsequent registered user is not admin';
    is $reg_user->is_operator, 0, 'subsequent registered user is not operator';
    is $schema->resultset('AuditEvents')->search({user_id => $reg_user->id, event => 'user_register'})->count, 1,
      'audit event user_register recorded for subsequent user';
};

subtest 'registered user authentication and interface state' => sub {
    $t->post_ok('/login', form => {username => 'regularuser', password => 'regularpass123'})
      ->status_is(302, 'login with newly registered credentials returns redirect status');

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'authenticated test overview request succeeds')
          ->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as regularuser/, 'user interface shows logged in as newly registered user';
    $t->element_exists_not('a[href="/register"]', 'register link is hidden when user is logged in');

    $t->get_ok('/logout')->status_is(302, 'logout after registration test succeeds');
};

subtest 'password change access controls and form presentation' => sub {
    $t->get_ok('/password_change')->status_is(302, 'unauthenticated GET /password_change redirects')
      ->header_like(Location => qr{^/login\?return_page=}, 'unauthenticated GET /password_change redirects to login');

    $t->post_ok('/password_change', form => {old_password => 'foo', new_password => 'bar'})
      ->status_is(302, 'unauthenticated POST /password_change redirects')
      ->header_like(Location => qr{^/login\?return_page=}, 'unauthenticated POST /password_change redirects to login');

    $t->app->config->{auth}->{method} = 'Fake';
    $t->get_ok('/password_change')->status_is(403, 'GET /password_change forbidden when auth method is not Local');
    $t->post_ok('/password_change', form => {old_password => 'foo', new_password => 'bar'})
      ->status_is(403, 'POST /password_change forbidden when auth method is not Local');
    $t->app->config->{auth}->{method} = 'Local';

    $t->post_ok('/login', form => {username => 'localuser', password => 'correctpassword'})
      ->status_is(302, 'login as localuser succeeds');

    $t->get_ok('/tests')->status_is(200, 'tests page accessible when logged in')
      ->element_exists('#user-action a[href="/password_change"]',
        'change password link exists in navbar dropdown for local user');

    $t->app->config->{auth}->{method} = 'Fake';
    $t->get_ok('/tests')->status_is(200, 'tests page accessible with non-local auth')
      ->element_exists_not('#user-action a[href="/password_change"]',
        'change password link hidden in navbar when auth is not Local');
    $t->app->config->{auth}->{method} = 'Local';

    $t->get_ok('/password_change')->status_is(200, 'password change form renders with status 200 on GET')
      ->element_exists('form[action="/password_change"][method="post"]',
        'form posting to password change endpoint exists')
      ->element_exists('input[name="csrf_token"][type="hidden"]', 'hidden csrf token field exists')
      ->element_exists('input#old_password[name="old_password"][type="password"]',
        'current password input field exists')
      ->element_exists('input#new_password[name="new_password"][type="password"]', 'new password input field exists')
      ->element_exists('input[type="submit"], button[type="submit"]', 'submit button exists');
};

subtest 'password change validation and CSRF enforcement' => sub {
    $t->post_ok('/password_change', form => {old_password => 'correctpassword', new_password => 'newsecurepass1'})
      ->status_is(403, 'status 403 returned when CSRF token is missing')
      ->content_is('Bad CSRF token!', 'CSRF error message returned when token missing');

    my $csrf_token = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted valid CSRF token from password change form';

    my @invalid_password_change_cases = (
        {
            desc => 'incorrect current password',
            form => {old_password => 'wrongpassword', new_password => 'newsecurepass1'},
            err => qr/Incorrect current password/,
        },
        {
            desc => 'empty current password',
            form => {old_password => '', new_password => 'newsecurepass1'},
            err => qr/Incorrect current password/,
        },
        {
            desc => 'missing current password',
            form => {new_password => 'newsecurepass1'},
            err => qr/Incorrect current password/,
        },
        {
            desc => 'empty new password',
            form => {old_password => 'correctpassword', new_password => ''},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'missing new password',
            form => {old_password => 'correctpassword'},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'too short new password',
            form => {old_password => 'correctpassword', new_password => 'short'},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'whitespace-only new password',
            form => {old_password => 'correctpassword', new_password => '        '},
            err => qr/Password cannot be whitespace only/,
        },
        {
            desc => 'new password matching username',
            form => {old_password => 'correctpassword', new_password => 'localuser'},
            err => qr/Password cannot match username/,
        },
    );

    for my $case (@invalid_password_change_cases) {
        $t->post_ok('/password_change', form => {%{$case->{form}}, csrf_token => $csrf_token})
          ->status_is(403, "status 403 returned for $case->{desc}")
          ->content_like($case->{err}, "expected policy error message for $case->{desc}");
    }
};

subtest 'successful password change, credential transition, and audit logging' => sub {
    my $user = $schema->resultset('Users')->find({username => 'localuser'});
    my $initial_audit_count
      = $schema->resultset('AuditEvents')->search({user_id => $user->id, event => 'user_password_change'})->count;

    my $csrf_token = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted valid CSRF token from password change form';

    $t->post_ok('/password_change',
        form => {old_password => 'correctpassword', new_password => 'newsecurepass1', csrf_token => $csrf_token})
      ->status_is(302, 'valid password change returns redirect status')
      ->header_is(Location => '/password_change', 'redirects to password change page');

    $t->get_ok('/password_change')->status_is(200, 'password change page displays after redirect')
      ->content_like(qr/Password changed successfully\./, 'success flash message rendered on password change page');

    is $schema->resultset('AuditEvents')->search({user_id => $user->id, event => 'user_password_change'})->count,
      $initial_audit_count + 1, 'user_password_change audit event recorded in database';

    $t->get_ok('/logout')->status_is(302, 'logout succeeds following password change');

    $t->post_ok('/login', form => {username => 'localuser', password => 'correctpassword'})
      ->status_is(403, 'old password no longer accepted for login')
      ->content_is('Invalid username or password', 'standard invalid credentials message returned for old password');

    $t->post_ok('/login', form => {username => 'localuser', password => 'newsecurepass1'})
      ->status_is(302, 'login with new password returns redirect status')
      ->header_is(Location => '/', 'login with new password redirects to home page');

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'authenticated test overview accessible after password change')
          ->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as localuser/, 'user interface shows user logged in under updated credentials';

    $t->get_ok('/logout')->status_is(302, 'final logout succeeds');
};

done_testing();
