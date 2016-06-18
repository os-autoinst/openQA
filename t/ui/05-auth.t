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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

#
# No login, no user-info and no api_keys
is($t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text, 'Login', 'no-one logged in');
$t->get_ok('/api_keys')->status_is(302);

# So let's log in as an unpriviledged user
$test_case->login($t, 'https://openid.camelot.uk/lancelot');
# ...who should see a logout option but no link to API keys
is($t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text, 'Logged in as lance Logout', 'lance is logged in');
$t->get_ok('/api_keys')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
is($t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text, 'Login', 'no-one logged in');

#
# Try creating new user by logging in
$test_case->login($t, 'morgana');
# ...who should see a logout option but no link to API keys
is($t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text, 'Logged in as morgana Logout', 'morgana as no api keys');
$t->get_ok('/api_keys')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
is($t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text, 'Login', 'no-one logged in');

#
# And log in as operator
$test_case->login($t, 'percival');
my $actions = $t->get_ok('/tests')->status_is(200)->tx->res->dom->at('#user-action')->all_text;
like($actions, qr/Logged in as perci Operators Menu.*Manage API keys Logout/, 'perci has operator links');
unlike($actions, qr/Administrators Menu/, 'perci has no admin links');

$t->get_ok('/api_keys')->status_is(200);

done_testing();
