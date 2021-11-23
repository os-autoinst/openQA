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
my $openid = OpenQA::WebAPI::Auth::OpenID->new();
my (%openid_res, %openid_res2);
my $vident = Test::MockObject->new->set_series('signed_extension_fields', \%openid_res, \%openid_res2);
$vident->{identity} = 'mordred';
my $mock = Test::MockModule->new('OpenQA::WebAPI::Auth::OpenID');
$mock->noop('_create_user');
$mock->mock('session', {});
ok $openid->_handle_verified($vident), 'can call _handle_verified';
done_testing;
