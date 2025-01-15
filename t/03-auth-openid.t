# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::MockObject;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebAPI::Auth::OpenID;


is OpenQA::WebAPI::Auth::OpenID::_first_last_name({'value.firstname' => 'Mordred'}), 'Mordred ',
  '_first_last_name concats also with empty fields';
my (%openid_res, %openid_res2);
my $vident = Test::MockObject->new->set_series('signed_extension_fields', \%openid_res, \%openid_res2);
my $user = $vident->{identity} = 'mordred';
my $users = Test::MockObject->new->set_always('create_user', 1);
my $schema = Test::MockObject->new->set_always(resultset => $users);
my %session;
my $c = Test::MockObject->new->set_always(schema => $schema);
ok OpenQA::WebAPI::Auth::OpenID::_create_user($c, $user, 'nobody\@example.com', $user, $user), 'can call _create_user';
$c->set_always(session => \%session);
ok OpenQA::WebAPI::Auth::OpenID::_handle_verified($c, $vident), 'can call _handle_verified';
$users->called_ok('create_user', 'new user is created for initial login');
is(($users->call_args(2))[1], 'mordred', 'new user created with details');
$c->set_always(
    req => Test::MockObject->new->set_always(
        params => Test::MockObject->new->set_always(pairs => ['openid.op_endpoint', 'https://www.opensuse.org/openid/'])
)->set_always(url => Test::MockObject->new->set_always(base => 'openqa')))
  ->set_always(
    app => Test::MockObject->new->set_always(config => {})->set_always(log => Test::MockObject->new->set_true('error')))
  ->set_true('flash');
is OpenQA::WebAPI::Auth::OpenID::auth_response($c), 0, 'can call auth_response';
$c->app->log->called_ok('error', 'an error was logged for call without proper config');

my $mock_openid_consumer = Test::MockModule->new('Net::OpenID::Consumer');
$mock_openid_consumer->redefine(
    'handle_server_response',
    sub ($self, %res_handlers) {
        return $res_handlers{setup_needed}
          ? $res_handlers{setup_needed}->("https://www.opensuse.org/openid/setup")
          : undef;
    });
$c->set_always(
    req => Test::MockObject->new->set_always(
        params => Test::MockObject->new->set_always(pairs => ['openid.op_endpoint', 'https://www.opensuse.org/openid/'])
)->set_always(url => Test::MockObject->new->set_always(base => 'openqa')))
  ->set_always(
    app => Test::MockObject->new->set_always(config => {})->set_always(log => Test::MockObject->new->set_true('debug')))
  ->set_true('flash');
is OpenQA::WebAPI::Auth::OpenID::auth_response($c), 0, 'can handle setup_needed response';
$c->app->log->called_ok('debug', 'a debug messgae is logged when setup_needed respond');
done_testing;
