# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
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
$vident->{identity} = 'mordred';
my $users = Test::MockObject->new->set_always('create_user', 1);
my $schema = Test::MockObject->new->set_always(resultset => $users);
my %session;
my $c
  = Test::MockObject->new->set_always(schema => $schema)->set_always(session => \%session)->set_true('_create_user');
ok OpenQA::WebAPI::Auth::OpenID::_handle_verified($c, $vident), 'can call _handle_verified';
$c->set_always(
    req => Test::MockObject->new->set_always(params => Test::MockObject->new->set_always(pairs => [1, 2]))
      ->set_always(url => Test::MockObject->new->set_always(base => 'openqa')))
  ->set_always(app => Test::MockObject->new->set_always(config => {})
      ->set_always(log => Test::MockObject->new->set_true('error', 'debug')))->set_true('flash');
is OpenQA::WebAPI::Auth::OpenID::auth_response($c), 0, 'can call auth_response';

done_testing;
