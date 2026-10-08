# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use DateTime;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '15';
use OpenQA::WebAPI::Auth::Local qw(hash_password);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::Util 'secure_compare';

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{auth}->{method} = 'Local';

BEGIN {
    unless (eval { require Crypt::Bcrypt; 1 }) {

        package Crypt::Bcrypt;
        $INC{'Crypt/Bcrypt.pm'} = 'mocked';
        sub bcrypt { }
        sub bcrypt_check { }
    }
}

my $mock_bcrypt = Test::MockModule->new('Crypt::Bcrypt');
$mock_bcrypt->redefine(
    bcrypt => sub {
        my ($pw, $subtype, $cost, $salt) = @_;
        return '$2b$' . $cost . '$' . unpack('H*', $salt) . $pw;
    });
$mock_bcrypt->redefine(
    bcrypt_check => sub {
        my ($pw, $hash) = @_;
        return 0 unless $hash =~ /^\$2b\$12\$([0-9a-f]{32})(.*)$/;
        return secure_compare($2, $pw);
    });

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
            desc => 'too long password',
            form => {username => 'validuser', password => 'a' x 129},
            err => qr/Password must be at most 128 characters/
        },
        {
            desc => 'password containing username',
            form => {username => 'containuser', password => 'xcontainuser1234'},
            err => qr/Password cannot match username/
        },
        {
            desc => 'common password',
            form => {username => 'validuser', password => 'password123'},
            err => qr/Password is too common/
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

subtest 'hardened password policy still accepts existing valid passwords' => sub {
    my @accepted_registration_cases = (
        {desc => 'password with letters and digits', username => 'hardeneduser1', password => 'validpass123'},
        {
            desc => 'password previously accepted before hardening',
            username => 'hardeneduser2',
            password => 'correctpassword'
        },
        {desc => 'password at the 128 character maximum boundary', username => 'hardeneduser3', password => 'x' x 128},
        {desc => 'password with symbols and digits', username => 'hardeneduser4', password => 'Sup3r$ecure!'},
    );

    for my $case (@accepted_registration_cases) {
        $t->post_ok('/register', form => {username => $case->{username}, password => $case->{password}})
          ->status_is(302, "registration accepted for $case->{desc}")
          ->header_is(Location => '/login', "successful registration redirects to login for $case->{desc}");
    }
};

subtest 'password change access controls and form presentation' => sub {
    $t->get_ok('/password_change')->status_is(302, 'unauthenticated GET /password_change redirects')
      ->header_like(Location => qr{^/login\?return_page=}, 'unauthenticated GET /password_change redirects to login');

    $t->post_ok('/password_change', form => {new_password => 'newpassword1'})
      ->status_is(302, 'unauthenticated POST /password_change redirects')
      ->header_like(Location => qr{^/login\?return_page=}, 'unauthenticated POST /password_change redirects to login');

    $t->app->config->{auth}->{method} = 'Fake';
    $t->get_ok('/password_change')->status_is(403, 'GET /password_change forbidden when auth method is not Local');
    $t->post_ok('/password_change', form => {new_password => 'newpassword1'})
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
      ->element_exists_not('input#old_password[name="old_password"]',
        'no current password input field rendered; the session alone authorizes the change')
      ->element_exists('input#new_password[name="new_password"][type="password"]', 'new password input field exists')
      ->element_exists('input[type="submit"], button[type="submit"]', 'submit button exists')
      ->element_exists('form[action="/delete_account"][method="post"]',
        'form posting to delete account endpoint exists')
      ->element_exists('form[action="/delete_account"] input[name="csrf_token"][type="hidden"]',
        'delete account form contains csrf token field')
      ->element_exists('form[action="/delete_account"] input[type="submit"][value="Delete Account"]',
        'delete account submit button exists');
};

subtest 'password change validation and CSRF enforcement' => sub {
    $t->post_ok('/password_change', form => {new_password => 'newsecurepass1'})
      ->status_is(403, 'status 403 returned when CSRF token is missing')
      ->content_is('Bad CSRF token!', 'CSRF error message returned when token missing');

    my $csrf_token = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted valid CSRF token from password change form';

    my @invalid_password_change_cases = (
        {
            desc => 'missing new password',
            form => {},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'empty new password',
            form => {new_password => ''},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'too short new password',
            form => {new_password => 'short'},
            err => qr/Password must be at least 8 characters/,
        },
        {
            desc => 'whitespace-only new password',
            form => {new_password => '        '},
            err => qr/Password cannot be whitespace only/,
        },
        {
            desc => 'too long new password',
            form => {new_password => 'a' x 129},
            err => qr/Password must be at most 128 characters/,
        },
        {
            desc => 'new password containing username',
            form => {new_password => 'localuser1234'},
            err => qr/Password cannot match username/,
        },
        {
            desc => 'common new password',
            form => {new_password => 'password123'},
            err => qr/Password is too common/,
        },
        {
            desc => 'new password matching username',
            form => {new_password => 'localuser'},
            err => qr/Password cannot match username/,
        },
        {
            desc => 'stale old_password field is ignored and only new password policy is enforced',
            form => {old_password => 'totallywrongpassword', new_password => 'short'},
            err => qr/Password must be at least 8 characters/,
        },
    );

    for my $case (@invalid_password_change_cases) {
        $t->post_ok('/password_change', form => {%{$case->{form}}, csrf_token => $csrf_token})
          ->status_is(403, "status 403 returned for $case->{desc}")
          ->content_like($case->{err}, "expected policy error message for $case->{desc}");
    }
};

subtest 'successful password change invalidates session, credential transition, and audit logging' => sub {
    my $user = $schema->resultset('Users')->find({username => 'localuser'});
    my $initial_audit_count
      = $schema->resultset('AuditEvents')->search({user_id => $user->id, event => 'user_password_change'})->count;
    my $initial_epoch = $user->session_epoch // 0;

    my $csrf_token = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted valid CSRF token from password change form';

    $t->post_ok('/password_change', form => {new_password => 'newsecurepass1', csrf_token => $csrf_token})
      ->status_is(302, 'password change succeeds with only new_password and no old_password supplied')
      ->header_is(Location => '/password_change', 'successful password change redirects to password change page');

    is $schema->resultset('Users')->find({username => 'localuser'})->session_epoch, $initial_epoch + 1,
      'session_epoch incremented on password change to invalidate prior browser sessions';

    is $schema->resultset('AuditEvents')->search({user_id => $user->id, event => 'user_password_change'})->count,
      $initial_audit_count + 1, 'user_password_change audit event recorded in database';

    $t->get_ok('/password_change')
      ->status_is(302, 'password change page is not accessible after the change because the session was deleted')
      ->header_like(Location => qr{^/login\?return_page=}, 'invalidated session redirects back to login');

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'tests page accessible after password change')
          ->tx->res->dom->at('#user-action')->all_text);
    is $actions, 'Login', 'user interface shows the user must log in again after the password change';

    $t->post_ok('/login', form => {username => 'localuser', password => 'correctpassword'})
      ->status_is(403, 'old password no longer accepted for login')
      ->content_is('Invalid username or password', 'standard invalid credentials message returned for old password');

    $t->post_ok('/login', form => {username => 'localuser', password => 'newsecurepass1'})
      ->status_is(302, 'login with new password returns redirect status')
      ->header_is(Location => '/', 'login with new password redirects to home page');

    $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'authenticated test overview accessible after password change')
          ->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as localuser/, 'user interface shows user logged in under updated credentials';

    $t->get_ok('/logout')->status_is(302, 'final logout succeeds');
};

subtest 'stale browser session with pre-change epoch is rejected after credential change' => sub {
    my $cookie = (grep { $_->name eq $t->app->sessions->cookie_name } @{$t->ua->cookie_jar->all})[0];
    my $c = $t->app->build_controller;
    $c->req->cookies($cookie);
    $t->app->sessions->load($c);
    $c->session->{user} = 'localuser';
    $c->session->{epoch} = 0;
    $t->app->sessions->store($c);
    $cookie->value($c->res->cookie($t->app->sessions->cookie_name)->value);

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'tests page accessible with forged pre-change-epoch session')
          ->tx->res->dom->at('#user-action')->all_text);
    is $actions, 'Login', 'forged session carrying the pre-change epoch does not resolve to localuser';

    $t->post_ok('/login', form => {username => 'localuser', password => 'newsecurepass1'})
      ->status_is(302, 'fresh login stores the current epoch and succeeds')
      ->header_is(Location => '/', 'login redirects to index page');

    $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'tests page accessible after fresh login')
          ->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as localuser/, 'session with the current epoch resolves to localuser';
};

subtest 'account deletion access controls and system user guard' => sub {
    $t->get_ok('/logout')->status_is(302, 'logout before unauthenticated delete account check');

    $t->post_ok('/delete_account', form => {csrf_token => 'dummy'})
      ->status_is(302, 'unauthenticated POST /delete_account returns redirect')
      ->header_like(Location => qr{^/login\?return_page=}, 'unauthenticated POST /delete_account redirects to login');

    $t->app->config->{auth}->{method} = 'Fake';
    $t->post_ok('/delete_account', form => {csrf_token => 'dummy'})
      ->status_is(403, 'POST /delete_account forbidden when auth method is not Local');
    $t->app->config->{auth}->{method} = 'Local';

    $t->post_ok('/login', form => {username => 'localuser', password => 'newsecurepass1'})
      ->status_is(302, 'login as localuser succeeds before CSRF check');

    $t->post_ok('/delete_account')->status_is(403, 'POST /delete_account without CSRF token returns 403')
      ->content_is('Bad CSRF token!', 'CSRF error message returned when token missing');

    my $system_user = $schema->resultset('Users')->find_or_create(
        {
            username => 'system',
            provider => '',
            email => 'noemail@open.qa',
            fullname => 'openQA system user',
            nickname => 'system',
        });

    my $cookie = (grep { $_->name eq $t->app->sessions->cookie_name } @{$t->ua->cookie_jar->all})[0];
    my $c = $t->app->build_controller;
    $c->req->cookies($cookie);
    $t->app->sessions->load($c);
    $c->session->{user} = 'system';
    $c->session->{epoch} = $system_user->session_epoch // 0;
    $t->app->sessions->store($c);
    $cookie->value($c->res->cookie($t->app->sessions->cookie_name)->value);
    my $system_csrf = $c->csrf_token;

    $t->post_ok('/delete_account', form => {csrf_token => $system_csrf})
      ->status_is(403, 'POST /delete_account for system user returns 403')
      ->content_like(qr/Cannot delete system user/, 'error message confirms system user cannot be deleted');

    $t->get_ok('/logout')->status_is(302, 'logout succeeds');
};

subtest 'successful self-deletion of local user account' => sub {
    my $user_to_delete = $schema->resultset('Users')->create_user(
        'selfdeleteuser',
        provider => 'Local',
        password => hash_password('selfdelpass123'),
    );
    my $del_id = $user_to_delete->id;

    $t->post_ok('/login', form => {username => 'selfdeleteuser', password => 'selfdelpass123'})
      ->status_is(302, 'login as selfdeleteuser returns redirect status');

    my $csrf_token = $t->get_ok('/password_change')->status_is(200, 'password change page accessible')
      ->tx->res->dom->at('form[action="/delete_account"] input[name="csrf_token"]')->attr('value');
    ok $csrf_token, 'extracted valid CSRF token from delete account form';

    $t->post_ok('/delete_account', form => {csrf_token => $csrf_token})
      ->status_is(302, 'valid delete account request returns redirect status')
      ->header_is(Location => '/', 'account deletion redirects to index page');

    $t->get_ok('/')->status_is(200, 'index page renders successfully after account deletion')
      ->content_like(qr/Account deleted successfully\./, 'success flash message rendered on home page');

    $user_to_delete->discard_changes;
    ok $user_to_delete->is_deleted, 'deleted user has deleted_at timestamp populated';
    is $user_to_delete->username, "deleted-user-$del_id", 'deleted user username anonymized to deleted-user-id pattern';
    is $user_to_delete->email, undef, 'deleted user email is cleared';
    is $schema->resultset('AuditEvents')->search({user_id => $del_id, event => 'user_delete_account'})->count, 1,
      'user_delete_account audit event recorded in database';

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'tests page accessible after deletion')->tx->res->dom->at('#user-action')
          ->all_text);
    is $actions, 'Login', 'user interface confirms session was invalidated and user is unauthenticated';

    $t->post_ok('/login', form => {username => 'selfdeleteuser', password => 'selfdelpass123'})
      ->status_is(403, 'login with original username of deleted account is rejected')
      ->content_is('Invalid username or password', 'expected authentication failure error for original username');

    $t->post_ok('/login', form => {username => "deleted-user-$del_id", password => 'selfdelpass123'})
      ->status_is(403, 'login with anonymized username is rejected')
      ->content_is('Invalid username or password', 'expected authentication failure error for anonymized username');
};

subtest 'admin user deletion access controls and system user guard' => sub {
    my $system_user = $schema->resultset('Users')->find_or_create(
        {
            username => 'system',
            provider => '',
            email => 'noemail@open.qa',
            fullname => 'openQA system user',
            nickname => 'system',
        });
    my $sys_id = $system_user->id;

    $t->post_ok("/admin/user/$sys_id/delete", form => {csrf_token => 'dummy'})
      ->status_is(302, 'unauthenticated admin delete request redirects to login')
      ->header_like(Location => qr{^/login\?return_page=}, 'redirect target points to login');

    $t->post_ok('/login', form => {username => 'regularuser', password => 'regularpass123'})
      ->status_is(302, 'login as regular non-admin user succeeds');

    my $reg_csrf = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    $t->post_ok("/admin/user/$sys_id/delete", form => {csrf_token => $reg_csrf})
      ->status_is(403, 'non-admin attempt to delete user returns status 403');

    $t->get_ok('/logout')->status_is(302, 'logout from regular user succeeds');

    $t->post_ok('/login', form => {username => 'firstadmin', password => 'secureadminpass'})
      ->status_is(302, 'login as admin succeeds');

    my $admin_csrf = $t->get_ok('/admin/users')->status_is(200, 'admin users page accessible')
      ->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $admin_csrf, 'extracted valid CSRF token from admin users page';

    $t->post_ok("/admin/user/$sys_id/delete")->status_is(403, 'admin delete request without CSRF token returns 403')
      ->content_is('Bad CSRF token!', 'CSRF error message returned when token missing');

    $t->post_ok('/admin/user/99999999/delete', form => {csrf_token => $admin_csrf})
      ->status_is(404, 'admin delete of non-existent user returns 404')
      ->content_is("Can't find that user", 'not found message returned for unknown user');

    $t->post_ok("/admin/user/$sys_id/delete", form => {csrf_token => $admin_csrf})
      ->status_is(403, 'admin deletion of system user refused with status 403')
      ->content_is('Cannot delete system user', 'error message confirms system user cannot be deleted');

    $system_user->discard_changes;
    ok !$system_user->is_deleted, 'system user is preserved and not marked as deleted';
    is $system_user->username, 'system', 'system user username remains unchanged';
};

subtest 'admin deleting another user account' => sub {
    my $system_user = $schema->resultset('Users')->find({username => 'system', provider => ''});
    my $sys_id = $system_user->id;

    my $target_user = $schema->resultset('Users')->create_user(
        'admintargetuser',
        provider => 'Local',
        password => hash_password('targetsecret1'),
    );
    my $target_id = $target_user->id;

    my $admin_csrf
      = $t->get_ok('/admin/users')->status_is(200, 'admin users page accessible')
      ->text_is('thead th:nth-child(5)', 'Provider', 'provider table header is displayed')
      ->text_is("#user_$target_id .provider", 'Local', 'target user row displays Local provider')
      ->element_exists(qq{#user_$target_id form[action="/admin/user/$target_id/delete"][method="POST"]},
        'delete form present for active local user')
      ->element_exists(qq{#user_$target_id form[action="/admin/user/$target_id/delete"] input[name="csrf_token"]},
        'delete form contains csrf token')
      ->element_exists(
        qq{#user_$target_id form[action="/admin/user/$target_id/delete"] input[type="submit"][value="Delete"]},
        'delete form contains submit button')
      ->element_exists_not(qq{#user_$sys_id form[action="/admin/user/$sys_id/delete"]},
        'delete form not rendered for system user')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $admin_csrf, 'extracted valid CSRF token for admin delete request';

    $t->post_ok("/admin/user/$target_id/delete", form => {csrf_token => $admin_csrf})
      ->status_is(302, 'admin delete of local user returns redirect')
      ->header_is(Location => '/admin/users', 'redirects back to admin users list');

    $t->get_ok('/admin/users')->status_is(200, 'admin users list accessible after deletion')
      ->content_like(qr/User deleted successfully\./, 'success flash message displayed on admin users page')
      ->element_exists_not(qq{#user_$target_id form[action="/admin/user/$target_id/delete"]},
        'delete form not rendered for already deleted user');

    $target_user->discard_changes;
    ok $target_user->is_deleted, 'target user is marked as deleted in database';
    is $target_user->username, "deleted-user-$target_id", 'target user username is anonymized';
    is $schema->resultset('AuditEvents')->search({user_id => $target_id, event => 'user_delete_account'})->count, 1,
      'user_delete_account audit event recorded for target user';

    my $actions
      = OpenQA::Test::Case::trim_whitespace(
        $t->get_ok('/tests')->status_is(200, 'tests page accessible')->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/Logged in as firstadmin/, 'admin session remains active after deleting another user';

    $t->get_ok('/logout')->status_is(302, 'admin logout succeeds');

    $t->post_ok('/login', form => {username => 'admintargetuser', password => 'targetsecret1'})
      ->status_is(403, 'login with deleted user username rejected')
      ->content_is('Invalid username or password', 'authentication failure message');

    $t->post_ok('/login', form => {username => "deleted-user-$target_id", password => 'targetsecret1'})
      ->status_is(403, 'login with anonymized username rejected')
      ->content_is('Invalid username or password', 'authentication failure message');
};

subtest 'admin managing local user roles and permissions' => sub {
    my $manage_user = $schema->resultset('Users')->create_user(
        'rolechangeuser',
        nickname => 'rolechange',
        provider => 'Local',
        password => hash_password('rolechangepass'),
    );
    my $user_id = $manage_user->id;

    $t->post_ok('/login', form => {username => 'regularuser', password => 'regularpass123'})
      ->status_is(302, 'login as regular non-admin user succeeds');

    my $reg_csrf = $t->get_ok('/password_change')->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    $t->post_ok("/admin/users/$user_id", form => {csrf_token => $reg_csrf, role => 'admin'})
      ->status_is(403, 'non-admin attempt to update user role returns status 403');

    $t->get_ok('/logout')->status_is(302, 'logout from regular user succeeds');

    $t->post_ok('/login', form => {username => 'firstadmin', password => 'secureadminpass'})
      ->status_is(302, 'login as admin succeeds');

    my $admin_csrf = $t->get_ok('/admin/users')->status_is(200, 'admin users page accessible')
      ->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    ok $admin_csrf, 'extracted valid CSRF token from admin users page';

    is $t->tx->res->dom->at("#user_$user_id .role")->attr('data-order'), '00',
      'initial user role is non-operator non-admin';

    $t->post_ok("/admin/users/$user_id", form => {csrf_token => $admin_csrf, role => 'operator'})
      ->status_is(302, 'promote local user to operator returns redirect')
      ->header_is(Location => '/admin/users', 'redirects back to admin users list');

    $t->get_ok('/admin/users')->status_is(200, 'admin users page reloaded after role change');
    is $t->tx->res->dom->at("#user_$user_id .role")->attr('data-order'), '01',
      'user promoted to operator has updated role data-order 01';

    $t->post_ok(
        "/admin/users/$user_id",
        {'X-CSRF-Token' => $admin_csrf, Accept => 'application/json'},
        form => {role => 'admin'}
    )->status_is(200, 'promote local user to admin with json accept returns status 200')
      ->json_is('/status', 'User rolechange updated', 'json response confirms role update');

    $t->get_ok('/admin/users')->status_is(200, 'admin users page reloaded after second role change');
    is $t->tx->res->dom->at("#user_$user_id .role")->attr('data-order'), '11',
      'user promoted to admin has updated role data-order 11';

    $t->post_ok("/admin/users/$user_id", form => {csrf_token => $admin_csrf, role => 'user'})
      ->status_is(302, 'demote local user back to regular user returns redirect');

    $t->get_ok('/admin/users')->status_is(200, 'admin users page reloaded after demotion');
    is $t->tx->res->dom->at("#user_$user_id .role")->attr('data-order'), '00',
      'demoted user has role data-order reset to 00';

    $t->post_ok(
        '/admin/users/99999999',
        {'X-CSRF-Token' => $admin_csrf, Accept => 'application/json'},
        form => {role => 'admin'}
    )->status_is(404, 'role update for non-existent user with json accept returns 404')
      ->json_is('/error', "Can't find that user", 'json response contains error message for non-existent user');

    $t->post_ok('/admin/users/99999999', form => {csrf_token => $admin_csrf, role => 'admin'})
      ->status_is(302, 'role update for non-existent user without json accept returns redirect');

    $t->get_ok('/admin/users')->status_is(200, 'admin users page reloaded after error')->text_like(
        '#flash-messages span',
        qr/Can't find that user/,
        'flash error displayed when updating non-existent user'
    );

    $t->get_ok('/logout')->status_is(302, 'admin logout succeeds');
};

done_testing();
