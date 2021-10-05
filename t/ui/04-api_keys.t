# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

#
# No login, no api_keys
$t->get_ok('/api_keys')->status_is(302);

#
# So let's grab the CSRF token and login as Percival
$t->get_ok('/tests');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
$test_case->login($t, 'percival');

#
# And perform some 'legitimate' actions

# Percival can see all his keys, but not the Lancelot's one
$t->get_ok('/api_keys')->status_is(200)->element_exists('#api_key_3', 'keys are there')
  ->element_exists('#api_key_4', 'keys are there')->element_exists('#api_key_5', 'keys are there')
  ->element_exists_not('#api_key_99901', "no other users's keys")->text_isnt('#api_key_3 .expiration' => 'never')
  ->text_is('#api_key_5 .expiration' => 'never');

# When clicking in 'create' a new API key is displayed in the listing
$t->post_ok('/api_keys', {'X-CSRF-Token' => $token} => form => {})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->element_exists('#api_key_3', 'keys are there')
  ->element_exists('#api_key_6', 'keys are there');

# It's also possible to specify an expiration date
$t->post_ok('/api_keys', {'X-CSRF-Token' => $token} => form => {t_expiration => '2016-01-05'})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->text_is('#api_key_6 .expiration' => 'never')
  ->text_like('#api_key_7 .expiration' => qr/2016-01-05/);

# check invalid expiration date
$t->post_ok('/api_keys', {'X-CSRF-Token' => $token} => form => {t_expiration => 'asdlfj'})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->element_exists_not('#api_key_8', "No invalid key created")
  ->element_exists('#flash-messages .alert-danger', "Error message displayed");

# And to delete keys
$t->delete_ok('/api_keys/6', {'X-CSRF-Token' => $token})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->element_exists_not('#api_key_6', 'API key 6 is gone')
  ->content_like(qr/API key deleted/, 'deletion is reported');

#
# Now let's try to cheat the system

# Try to delete Lancelot's key
$t->delete_ok('/api_keys/99901', {'X-CSRF-Token' => $token})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->content_like(qr/API key not found/, 'error is displayed');

# Try to create an API key for Lancelot
$t->post_ok('/api_keys', {'X-CSRF-Token' => $token} => form => {user_id => 99902, user => 99902})->status_is(302);
$t->get_ok('/api_keys')->status_is(200)->element_exists('#api_key_3', 'Percival keys are there')
  ->element_exists('#api_key_8', 'and the new one belongs to Percival, not Lancelot');

done_testing();
