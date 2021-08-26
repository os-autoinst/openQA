# Copyright (C) 2020-2021 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::MockModule;
use Test::Mojo;
use Test::Output 'combined_like';
use Test::Warnings;
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebAPI::Auth::OAuth2;
use Mojo::File qw(tempdir path);
use Mojo::Transaction;
use Mojo::URL;
use MIME::Base64 qw(encode_base64url decode_base64url);

my $t;
my $tempdir = tempdir("/tmp/$FindBin::Script-XXXX")->make_path;
$ENV{OPENQA_CONFIG} = $tempdir;

sub test_auth_method_startup {
    my ($auth, @options) = @_;
    my @conf = ("[auth]\n", "method = \t  $auth \t\n", "[openid]\n", "httpsonly = 0\n");
    $tempdir->child("openqa.ini")->spurt(@conf, @options);

    $t = Test::Mojo->new('OpenQA::WebAPI');
    is $t->app->config->{auth}->{method}, $auth, "started successfully with auth $auth";
    $t->get_ok('/login' => {"Referer" => "http://open.qa/tests/42"});
}

OpenQA::Test::Database->new->create;

combined_like { test_auth_method_startup('Fake')->status_is(302) } qr/302 Found/, 'Plugin loaded';

subtest OpenID => sub {
    # openid relies on external server which we mock to not rely on external
    # dependencies
    my $openid_mock = Test::MockModule->new('Net::OpenID::Consumer');
    $openid_mock->redefine(
        claimed_identity => sub {
            return Net::OpenID::ClaimedIdentity->new(
                identity         => 'http://specs.openid.net/auth/2.0/identifier_select',
                delegate         => 'http://specs.openid.net/auth/2.0/identifier_select',
                server           => 'https://www.opensuse.org/openid/',
                consumer         => shift,
                protocol_version => 2,
                semantic_info    => undef
            );
        });
    my $url        = Mojo::URL->new(test_auth_method_startup('OpenID')->status_is(302)->tx->res->headers->location);
    my $return_url = Mojo::URL->new($url->query->param('openid.return_to'));
    is($return_url->query->param('return_page'), encode_base64url("/tests/42"), "return page set");

    $t = Test::Mojo->new('OpenQA::WebAPI');
    $openid_mock->redefine(
        handle_server_response => sub { },
        args                   => sub {
            my ($self, $query) = @_;
            my %args = (return_page => encode_base64url("/tests/42"));
            return $args{$query};
        });
    is($t->get_ok('/response')->status_is(302)->tx->res->headers->location,
        "/tests/42", "redirect to original papge after login");

};

subtest OAuth2 => sub {
    lives_ok { $t->app->plugin(OAuth2 => {mocked => {key => 'deadbeef'}}) } 'auth mocked';
    throws_ok { test_auth_method_startup 'OAuth2' } qr/No OAuth2 provider selected/, 'Error with no provider selected';
    throws_ok { test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = foo\n")) }
    qr/OAuth2 provider 'foo' not supported/, 'Error with unsupported provider';
    combined_like { test_auth_method_startup('OAuth2', ("[oauth2]\n", "provider = github\n")) } qr/302 Found/,
      'Plugin loaded';

    my $ua_mock  = Test::MockModule->new('Mojo::UserAgent');
    my $msg_mock = Test::MockModule->new('Mojo::Message');
    my @get_args;
    my $get_tx = Mojo::Transaction->new;
    $ua_mock->redefine(get => sub { shift; push @get_args, [@_]; $get_tx });

    my $c             = $t->app->build_controller;
    my %main_cfg      = (provider     => 'custom');
    my %provider_cfg  = (user_url     => 'http://does-not-exist', token_label => 'bar', nickname_from => 'login');
    my %data          = (access_token => 'some-token');
    my %expected_user = (username     => 42, provider => 'oauth2@custom', nickname => 'Demo');
    my $users         = $t->app->schema->resultset('Users');

    subtest 'failure when requesting user details' => sub {
        $get_tx->res->error({code => 500, message => 'Internal server error'});
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 403,                                   'status code';
        is $c->res->body, '500 response: Internal server error', 'error message';
        is $c->session->{user}, undef, 'user not set';
        is_deeply \@get_args, [['http://does-not-exist', {Authorization => 'bar some-token'}]], 'args for get request'
          or diag explain \@get_args;
    };

    subtest 'OAuth provider does not provide all mandatory user details' => sub {
        $get_tx->res->error(undef)->body('{}');
        OpenQA::WebAPI::Auth::OAuth2::update_user($c, \%main_cfg, \%provider_cfg, \%data);
        is $c->res->code, 403,                                                     'status code';
        is $c->res->body, 'User data returned by OAuth2 provider is insufficient', 'error message';
        is $c->session->{user}, undef, 'user not set';
    };

    subtest 'requesting user details succeeds' => sub {
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
