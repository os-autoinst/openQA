# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::MockObject;
use Test::Output 'combined_like';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebAPI::Auth::OpenID;
use Mojo::Headers;
use Mojo::URL;

is OpenQA::WebAPI::Auth::OpenID::_first_last_name({'value.firstname' => 'Mordred'}), 'Mordred ',
  '_first_last_name concats also with empty fields';
my (%openid_res, %openid_res2);
my $vident = Test::MockObject->new->set_series('signed_extension_fields', \%openid_res, \%openid_res2);
my $user = $vident->{identity} = 'mordred';
my $users = Test::MockObject->new->set_always('create_user', 1);
my $schema = Test::MockObject->new->set_always(resultset => $users);
my %session;
my $url = Mojo::URL->new(base => Mojo::URL->new('openqa'));
my $c = Test::MockObject->new->set_always(schema => $schema)->set_always(param => 'foo');
$c->set_always(config => {openid => {provider => 'foo'}});
ok OpenQA::WebAPI::Auth::OpenID::_create_user($c, $user, 'nobody\@example.com', $user, $user), 'can call _create_user';
$c->set_always(session => \%session);
ok +OpenQA::WebAPI::Auth::OpenID::_handle_verified($c, $vident), 'can call _handle_verified';
$users->called_ok('create_user', 'new user is created for initial login');
is + ($users->call_args(2))[1], 'mordred', 'new user created with details';
$c->set_always(
    req => Test::MockObject->new->set_always(
        params => Test::MockObject->new->set_always(pairs => ['openid.op_endpoint', 'https://www.opensuse.org/openid/'])
    )->set_always(url => $url))
  ->set_always(
    app => Test::MockObject->new->set_always(config => {})->set_always(log => Test::MockObject->new->set_true('error')))
  ->set_true('flash');
is +OpenQA::WebAPI::Auth::OpenID::auth_response($c), 0, 'can call auth_response';
$c->app->log->called_ok('error', 'an error was logged for call without proper config');

my $mock_openid_consumer = Test::MockModule->new('Net::OpenID::Consumer');
$mock_openid_consumer->redefine(
    'handle_server_response',
    sub ($self, %res_handlers) {
        return $res_handlers{setup_needed}
          ? $res_handlers{setup_needed}->('https://www.opensuse.org/openid/setup')
          : undef;
    });
$c->set_always(
    req => Test::MockObject->new->set_always(
        params => Test::MockObject->new->set_always(pairs => ['openid.op_endpoint', 'https://www.opensuse.org/openid/'])
    )->set_always(headers => Mojo::Headers->new)->set_always(url => $url))
  ->set_always(
    app => Test::MockObject->new->set_always(config => {})->set_always(log => Test::MockObject->new->set_true('debug')))
  ->set_true('flash');
is OpenQA::WebAPI::Auth::OpenID::auth_response($c), 0, 'can handle setup_needed response';
$c->app->log->called_ok('debug', 'a debug message is logged when setup_needed respond');

subtest 'claiming identity provider fails' => sub {
    $mock_openid_consumer->redefine(claimed_identity => undef);
    combined_like { OpenQA::WebAPI::Auth::OpenID::auth_login($c) } qr/claiming.*identity.*failed/i, 'error logged';
};

subtest 'login fails' => sub {
    my $claimed_id = Test::MockObject->new->set_true('set_extension_args')->set_false('check_url');
    $mock_openid_consumer->redefine(claimed_identity => $claimed_id);
    $mock_openid_consumer->redefine(err => 'test error');
    my %res = OpenQA::WebAPI::Auth::OpenID::auth_login($c);
    is_deeply \%res, {error => 'test error'}, 'error returned' or always_explain \%res;
};

subtest 'debug logging' => sub {
    my $csr;
    $mock_openid_consumer->redefine(new => sub (@args) { $csr = $mock_openid_consumer->original('new')->(@args) });
    my %res = OpenQA::WebAPI::Auth::OpenID::auth_response($c);
    $csr->{debug}->('foo', 'bar');
    $c->app->log->called_pos_ok(3, 'debug', 'a debug message is logged');
    $c->app->log->called_args_pos_is(3, 2, 'Net::OpenID::Consumer: foo bar', 'log message contains arguments');
    is_deeply \%res, {redirect => 'index', error => 0}, 'redirected to index' or always_explain \%res;
};

done_testing;
