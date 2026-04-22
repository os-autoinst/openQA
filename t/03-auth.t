# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::MockModule;
use Test::Mojo;
use Test::Output 'combined_like';
use Test::Warnings;
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebAPI::Auth::OAuth2;
use Mojo::File qw(tempdir path);
use Mojo::Transaction;
use Mojo::URL;
use MIME::Base64 qw(encode_base64url decode_base64url);
use Mojolicious;

my $file_api_mock = Test::MockModule->new('OpenQA::WebAPI::Controller::File');
$file_api_mock->redefine(download_asset => sub ($self) { $self->render(text => 'asset-ok') });
$file_api_mock->redefine(test_asset => sub ($self) { $self->redirect_to('/assets/iso/test.iso') });

# Mock assets to avoid "Too many open files" errors due to multiple app startups
my $assets_mock = Test::MockModule->new('OpenQA::Assets');
$assets_mock->redefine(
    setup => sub ($server) {
        $server->helper(asset => sub { '/dummy' });
    });

my $tempdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
$ENV{OPENQA_CONFIG} = $tempdir;
OpenQA::Test::Database->new->create;

sub test_auth_method_startup ($auth, @options) {
    my @conf = ("[auth]\n", "method = \t  $auth \t\n");
    $tempdir->child('openqa.ini')->spew(join '', @conf, @options, "[openid]\n", "httpsonly = 0\n");
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->app->helper(icon_url => sub { '/favicon.ico' });
    is $t->app->config->{auth}->{method}, $auth, "started successfully with auth $auth";
    $t->get_ok('/login' => {Referer => 'http://open.qa/tests/42'})->status_is(302, 'got redirected');
}

sub mojo_has_request_debug { $Mojolicious::VERSION <= 9.21 }

combined_like { test_auth_method_startup('Fake')->status_is(302) } mojo_has_request_debug ? qr/302 Found/ : qr//,
  'Plugin loaded';

subtest 'restricted asset downloads with setting `[auth] require_for_assets = 1`' => sub {
    my $t = test_auth_method_startup('Fake', "require_for_assets = 1\n");
    $t->get_ok('/session/test')->status_is(200)->content_like(qr/you are Demo/);
    $t->app->helper(valid_csrf => sub { 0 });
    $t->post_ok('/admin/users/1')->status_is(403)->content_like(qr/bad csrf token/i);
    $t->ua->max_redirects(1);    # follow redirection from `/tests/…/asset/…` to `/assets/…`
    my $expected_redirect = '/login?return_page=%2Fassets%2Fiso%2Ftest.iso';
    $t->get_ok('/assets/iso/test.iso')->status_is(200)->content_is('asset-ok', 'can access asset when logged in');
    $t->get_ok('/tests/42/asset/iso/test.iso')->status_is(200);
    $t->content_is('asset-ok', 'can access test asset when logged in');
    $t->get_ok('/logout')->status_is(200, 'logged out');
    $t->get_ok('/assets/iso/test.iso')->status_is(403, '403 response when logged out');
    $t->content_unlike(qr/asset-ok/, 'asset not accessible when logged out');
    $t->get_ok('/tests/42/asset/iso/test.iso')->status_is(403, '403 response via test when logged out');
    $t->content_unlike(qr/asset-ok/, 'asset via test not accessible when logged out');
};

subtest None => sub {
    my $t = test_auth_method_startup('None');
    my $key_val = 'DEADBEEFDEADBEEF';
    my $bearer_token = "Bearer admin:$key_val:$key_val";
    $t->get_ok('/session/test')->status_is(200)->content_like(qr/you are admin/);
    $t->get_ok('/admin/users')->status_is(200)->content_like(qr/Administrator/);

    my $user = $t->app->schema->resultset('Users')->find({username => 'admin'});
    ok $user, 'admin user exists';
    my $key = $user->api_keys->find({key => $key_val});
    ok $key, 'admin API key exists';
    is $key->secret, $key_val, 'admin API secret matches';
    is $key->t_expiration, undef, 'admin API key has no expiration';

    $t->get_ok('/api/v1/auth' => {Authorization => $bearer_token})->status_is(200)->content_is('ok');

    $user->audit_events->delete;
    $user->api_keys->delete;
    $user->delete;
    $t->get_ok('/login' => 'login as admin')->status_is(302);
    $t->get_ok('/session/test')->status_is(200)->content_like(qr/you are admin/);
    $user = $t->app->schema->resultset('Users')->find({username => 'admin'});
    ok $user, 'admin user re-created';
    ok $user->is_admin && $user->is_operator, 're-created user has admin/operator permissions';

    $user->update({is_admin => 0, is_operator => 0});
    $t->get_ok('/login' => 're-login as admin')->status_is(302);
    $t->get_ok('/session/test')->status_is(200)->content_like(qr/you are admin/);
    $user->discard_changes;
    ok $user->is_admin && $user->is_operator, 'login restored admin/operator permissions';

    $t->get_ok('/')->status_is(200)->content_unlike(qr/Logout/);

    {
        local $ENV{OPENQA_AUTH_NONE_KEY} = 'CUSTOMKEY';
        local $ENV{OPENQA_AUTH_NONE_SECRET} = 'CUSTOMSECRET';
        my $t2 = test_auth_method_startup('None');
        my $key2 = $t2->app->schema->resultset('ApiKeys')->find({key => 'CUSTOMKEY'});
        ok $key2, 'custom API key exists';
        is $key2->secret, 'CUSTOMSECRET', 'custom API secret matches';

        $t2->post_ok(
            '/api/v1/jobs/cancel',
            {'X-API-Key' => 'CUSTOMKEY', 'X-API-Microtime' => time},
            'fail auth on forged API header instead of bypassing CSRF'
        )->status_is(403)->content_unlike(qr/Bad CSRF token/i);
    }

    subtest 'CSRF security' => sub {
        my $t = test_auth_method_startup('None');
        my $url = '/api/v1/jobs/cancel';
        $t->get_ok('/login' => 'establish session')->status_is(302);
        $t->get_ok('/session/test' => 'logged in as admin')->status_is(200)->content_like(qr/you are admin/);

        $t->post_ok($url, {'X-API-Key' => 'JUNK_KEY'}, 'fail auth on forged API header instead of bypassing CSRF')
          ->status_is(403)->content_unlike(qr/Bad CSRF token/i);

        $t->post_ok(
            $url,
            {Authorization => 'Bearer JUNK_TOKEN'},
            'fail auth on forged Bearer header instead of bypassing CSRF'
        )->status_is(403)->content_unlike(qr/Bad CSRF token/i);
        $t->get_ok(
            '/api/v1/auth',
            {Authorization => $bearer_token},
            'pass auth on valid Bearer header despite existing session and missing CSRF'
        )->status_is(200)->content_is('ok');
        $t->post_ok($url, 'fail on missing CSRF token without API headers')->status_is(403)
          ->content_like(qr/Bad CSRF token/i);
    };
};

subtest OpenID => sub {
    # OpenID relies on external server which we mock to not rely on external dependencies
    my $openid_mock = Test::MockModule->new('Net::OpenID::Consumer');
    $openid_mock->redefine(
        claimed_identity => sub {
            return Net::OpenID::ClaimedIdentity->new(
                identity => 'http://specs.openid.net/auth/2.0/identifier_select',
                delegate => 'http://specs.openid.net/auth/2.0/identifier_select',
                server => 'https://www.opensuse.org/openid/',
                consumer => shift,
                protocol_version => 2,
                semantic_info => undef
            );
        });
    my $t = test_auth_method_startup('OpenID');
    my $url = Mojo::URL->new($t->status_is(302)->tx->res->headers->location);
    my $return_url = Mojo::URL->new($url->query->param('openid.return_to'));
    is $return_url->query->param('return_page'), encode_base64url('/tests/42'), 'return page set';

    $openid_mock->redefine(
        handle_server_response => sub ($self, %args) { },
        args => sub ($self, $query) { {return_page => encode_base64url('/tests/42')}->{$query} });
    $t->get_ok('/response')->status_is(302);
    $t->header_is('Location', '/tests/42', 'redirect to original page after login');

    $t->get_ok('/api_keys')->status_is(302);
    $t->header_is('Location', '/login?return_page=%2Fapi_keys', 'remember return_page for ensure_operator');
    $t->get_ok('/admin/users')->status_is(302);
    $t->header_is('Location', '/login?return_page=%2Fadmin%2Fusers', 'remember return_page for ensure_admin');
    $t->get_ok('/minion/stats')->status_is(200, 'minion stats is accessible unauthenticated (poo#110533)');

    subtest 'error handling' => sub {
        $t->ua->max_redirects(1);
        $openid_mock->redefine(
            handle_server_response => sub ($self, %args) { $args{error}->('some error', 'error message') },
            args => sub ($self, $query) { encode_base64url('/') },
        );
        combined_like {
            $t->get_ok('/response')->status_is(200, 'back on main page if error-callback invoked')
        }
        qr/OpenID: some error: error message/, 'error logged';
        my $flash = $t->tx->res->dom->at('#flash-messages')->all_text;
        like $flash, qr/some error: error message/, 'error shown as flash message' or always_explain $t->tx->res->body;
    };
};

subtest OAuth2 => sub {
    my $ua_mock = Test::MockModule->new('Mojo::UserAgent');
    my $msg_mock = Test::MockModule->new('Mojo::Message');
    my $get_tx = Mojo::Transaction->new;
    my @get_args;
    $ua_mock->redefine(get => sub ($ua, @args) { push @get_args, [@args]; $get_tx });

    my $t = Test::Mojo->new('OpenQA::WebAPI');
    lives_ok { $t->app->plugin(OAuth2 => {mocked => {key => 'deadbeef'}}) } 'auth mocked';

    subtest 'auth_login function via /login route' => sub {
        throws_ok { test_auth_method_startup 'OAuth2' } qr/No OAuth2 provider selected/,
          'Error with no provider selected';
        throws_ok { test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = foo\n")) }
        qr/OAuth2 provider 'foo' not supported/, 'Error with unsupported provider';
        $msg_mock->redefine(json => {id => 42, login => 'Demo'});
        combined_like {
            my $t = test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = github\n"));
            like $t->tx->res->headers->header('Location'), qr/github\.com/, 'redirection to GitHub';
            $t->get_ok('/login?code=foo')->status_is(403, 'login with wrong code prevented');
        }
        mojo_has_request_debug ? qr/302 Found/ : qr//, 'Plugin loaded';
    };

    my %main_cfg = (provider => 'custom');
    my %provider_cfg
      = (user_url => 'http://does-not-exist', token_label => 'bar', id_from => 'id', nickname_from => 'login');
    my %data = (access_token => 'some-token');
    my %expected_user = (username => 42, provider => 'oauth2@custom', nickname => 'Demo');
    my $users = $t->app->schema->resultset('Users');

    subtest 'failure when requesting user details' => sub {
        my $c = $t->app->build_controller;
        $get_tx->res->error({code => 500, message => 'Internal server error'});
        $msg_mock->unmock('json');
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 403, 'status code';
        is $c->res->body, '500 response: Internal server error', 'error message';
        is $c->session->{user}, undef, 'user not set';
        is_deeply \@get_args, [['http://does-not-exist', {Authorization => 'bar some-token'}]], 'args for get request'
          or always_explain \@get_args;
    };

    subtest 'OAuth provider does not provide all mandatory user details' => sub {
        my $c = $t->app->build_controller;
        $get_tx->res->error(undef)->body('{}');
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 403, 'status code';
        is $c->res->body, 'User data returned by OAuth2 provider is insufficient', 'error message';
        is $c->session->{user}, undef, 'user not set';
    };

    subtest 'requesting user details succeeds' => sub {
        my $c = $t->app->build_controller;
        $get_tx->res->error(undef);
        $msg_mock->redefine(json => {id => 42, login => 'Demo'});
        $t->app->helper(return_page => sub ($c) { 'http://test/foo/bar' });
        $t->app->config->{oauth2} = {provider_config => \%provider_cfg};
        throws_ok { OpenQA::WebAPI::Auth::OAuth2::auth_login($c) } qr/invalid provider/i,
          'auth login executed as far as needed to assign return page';
        is $c->session->{return_page}, 'http://test/foo/bar', 'page to return to saved via session';
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 302, 'status code (redirection)';
        is $c->res->headers->header('Location'), '/foo/bar', 'redirection to previous page (only path/query)';
        is $c->session->{user}, '42', 'user set';
        is $users->search(\%expected_user)->count, 1, 'user created';
        OpenQA::WebAPI::Auth::OAuth2::auth_logout($c);
        ok !exists $c->session->{return_page}, 'return page cleared on logout';
    };
};

throws_ok { test_auth_method_startup('nonexistant') } qr/Unable to load auth module/,
  'refused to start with non existent auth module';

done_testing;

END { path("$FindBin::Bin/data/openqa/share/factory/tmp")->remove_tree }
