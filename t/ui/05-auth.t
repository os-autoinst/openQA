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
    unshift @INC, 'lib', 'lib/OpenQA';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

#
# No login, no user-info and no api_keys
$t->get_ok('/tests')->status_is(200)->content_unlike(qr/Logged as/);
$t->get_ok('/api_keys')->status_is(403);

# So let's log in as an unpriviledged user...
$test_case->login($t, 'https://openid.camelot.uk/lancelot');
# ...who should see a logout option but no link to API keys
$t->get_ok('/tests')->status_is(200)->content_like(qr/Logged as lance (.*logout.*)/);
$t->get_ok('/api_keys')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
$t->get_ok('/tests')->status_is(200)->content_unlike(qr/Logged as/);

#
# Try creating new user by logging in
$test_case->login($t, 'https://openid.camelot.uk/morgana');
# ...who should see a logout option but no link to API keys
$t->get_ok('/tests')->status_is(200)->content_like(qr/Logged as morgana (.*logout.*)/);
$t->get_ok('/api_keys')->status_is(403);

#
# Then logout
$t->delete_ok('/logout')->status_is(302);
$t->get_ok('/tests')->status_is(200)->content_unlike(qr/Logged as/);

#
# And log in as operator
$test_case->login($t, 'https://openid.camelot.uk/percival');
$t->get_ok('/tests')->status_is(200)->content_like(qr/Logged as perci (.*manage API keys.* | .*logout.*)/);
$t->get_ok('/api_keys')->status_is(200);

done_testing();
