# Copyright (C) 2014-2020 SUSE LLC
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
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

# First of all, init the session (this should probably be in OpenQA::Test)
$t->get_ok('/tests');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');

#
# No login, no list, redirect to login
$t->get_ok('/admin/users')->status_is(302);

#
# Not even for operators
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'percival');
$t->get_ok('/admin/users')->status_is(403);

#
# So let's login as a admin
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'arthur');
$t->get_ok('/admin/users')->status_is(200);
is($t->tx->res->dom->at('#user_99901 .role')->attr('data-order'), '11');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '00');
is($t->tx->res->dom->at('#user_99903 .role')->attr('data-order'), '01');

# Click on "+ admin" for Lancelot
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {role => 'admin'})->status_is(302);
$t->get_ok('/admin/users')->status_is(200)->content_like(qr/User lance updated/)
  ->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '11');


# We can even update both fields in one request
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {role => 'operator'})->status_is(302);
$t->get_ok('/admin/users')->status_is(200)->content_like(qr/User lance updated/)
  ->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '01');

# not giving a role, makes it a user
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {})->status_is(302);
$t->get_ok('/admin/users')->status_is(200)->content_like(qr/User lance updated/)
  ->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '00');

done_testing();
