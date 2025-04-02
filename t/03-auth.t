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

my $tempdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
$ENV{OPENQA_CONFIG} = $tempdir;
OpenQA::Test::Database->new->create;

sub test_auth_method_startup ($auth, @options) {
    my @conf = ("[auth]\n", "method = \t  $auth \t\n");
    $tempdir->child('openqa.ini')->spew(join('', @conf, @options, "[openid]\n", "httpsonly = 0\n"));
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    is $t->app->config->{auth}->{method}, $auth, "started successfully with auth $auth";
    $t->get_ok('/login' => {Referer => 'http://open.qa/tests/42'});
}

sub mojo_has_request_debug { $Mojolicious::VERSION <= 9.21 }

combined_like { test_auth_method_startup('Fake')->status_is(302) } mojo_has_request_debug ? qr/302 Found/ : qr//,
  'Plugin loaded';

subtest 'restricted asset downloads with setting `[auth] require_for_assets = 1`' => sub {
    my $t = test_auth_method_startup('Fake', "require_for_assets = 1\n");
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
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    lives_ok { $t->app->plugin(OAuth2 => {mocked => {key => 'deadbeef'}}) } 'auth mocked';
    throws_ok { test_auth_method_startup 'OAuth2' } qr/No OAuth2 provider selected/, 'Error with no provider selected';
    throws_ok { test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = foo\n")) }
    qr/OAuth2 provider 'foo' not supported/, 'Error with unsupported provider';
    combined_like { test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = github\n")) }
    mojo_has_request_debug ? qr/302 Found/ : qr//, 'Plugin loaded';

    my $ua_mock = Test::MockModule->new('Mojo::UserAgent');
    my $msg_mock = Test::MockModule->new('Mojo::Message');
    my @get_args;
    my $get_tx = Mojo::Transaction->new;
    $ua_mock->redefine(get => sub { shift; push @get_args, [@_]; $get_tx });

    my %main_cfg = (provider => 'custom');
    my %provider_cfg
      = (user_url => 'http://does-not-exist', token_label => 'bar', id_from => 'id', nickname_from => 'login');
    my %data = (access_token => 'some-token');
    my %expected_user = (username => 42, provider => 'oauth2@custom', nickname => 'Demo');
    my $users = $t->app->schema->resultset('Users');

    subtest 'failure when requesting user details' => sub {
        my $c = $t->app->build_controller;
        $get_tx->res->error({code => 500, message => 'Internal server error'});
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
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 302, 'status code (redirection)';
        is $c->session->{user}, '42', 'user set';
        is $users->search(\%expected_user)->count, 1, 'user created';
    };
};

throws_ok { test_auth_method_startup('nonexistant') } qr/Unable to load auth module/,
  'refused to start with non existent auth module';

done_testing;
