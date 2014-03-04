# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

#
# No login, no api_keys
$t->get_ok('/api_keys')->status_is(403);

#
# So let's grab the CSRF token and login as Percival
my $req = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');
$test_case->login($t, 'https://openid.camelot.uk/percival');

#
# And perform some 'legitimate' actions

# Percival can see all his keys, but not the Lancelot's one
$req = $t->get_ok('/api_keys')->status_is(200);
$req->element_exists('#api_key_99902', 'keys are there');
$req->element_exists('#api_key_99903', 'keys are there');
$req->element_exists('#api_key_99904', 'keys are there');
$req->element_exists_not('#api_key_99901', "no other users's keys");
$req->text_isnt('#api_key_99902 .expiration' => '');
$req->text_is('#api_key_99904 .expiration' => '');

# When clicking in 'create' a new API key is displayed in the listing
$req = $t->post_ok('/api_keys', { 'X-CSRF-Token' => $token } => form => {})->status_is(302);
$req = $t->get_ok('/api_keys')->status_is(200);
$req->element_exists('#api_key_99902', 'keys are there');
$req->element_exists('#api_key_99905', 'keys are there');

# It's also possible to specify an expiration date
$req = $t->post_ok('/api_keys', { 'X-CSRF-Token' => $token } => form => {t_expiration => '2016-01-05'})->status_is(302);
$req = $t->get_ok('/api_keys')->status_is(200);
$req->text_is('#api_key_99905 .expiration' => '');
$req->text_like('#api_key_99906 .expiration' => qr/2016-01-05T/);

# And to delete keys
$req = $t->delete_ok('/api_keys/99905', { 'X-CSRF-Token' => $token })->status_is(302);
$req = $t->get_ok('/api_keys')->status_is(200);
$req->element_exists_not('#api_key_99905', 'API key 99905 is gone');
$req->content_like(qr/API key deleted/, 'deletion is reported');

#
# Now let's try to cheat the system

# Try to delete Lancelot's key
$req = $t->delete_ok('/api_keys/99901', { 'X-CSRF-Token' => $token })->status_is(302);
$req = $t->get_ok('/api_keys')->status_is(200);
$req->content_like(qr/API key not found/, 'error is displayed');

# Try to create an API key for Lancelot
$req = $t->post_ok('/api_keys', { 'X-CSRF-Token' => $token } => form => {user_id => 99902, user => 99902})->status_is(302);
$req = $t->get_ok('/api_keys')->status_is(200);
$req->element_exists('#api_key_99902', 'Percival keys are there');
$req->element_exists('#api_key_99907', 'and the new one belongs to Percival, not Lancelot');

done_testing();
