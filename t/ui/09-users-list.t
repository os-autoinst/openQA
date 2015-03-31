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
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More tests => 34;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

# First of all, init the session (this should probably be in OpenQA::Test)
my $req   = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');

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
my $get = $t->get_ok('/admin/users')->status_is(200);
is('11', $t->tx->res->dom->at('#user_99901 .role')->attr('data-order'));
is('00', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));
is('01', $t->tx->res->dom->at('#user_99903 .role')->attr('data-order'));

# Click on "+ admin" for Lancelot
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {role => 'admin'})->status_is(302);
$get = $t->get_ok('/admin/users')->status_is(200);
$get->content_like(qr/User lance updated/);
$get->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is('11', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));


# We can even update both fields in one request
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {role => 'operator'})->status_is(302);
$get = $t->get_ok('/admin/users')->status_is(200);
$get->content_like(qr/User lance updated/);
$get->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is('01', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));

# not giving a role, makes it a user
$t->post_ok('/admin/users/99902', {'X-CSRF-Token' => $token} => form => {})->status_is(302);
$get = $t->get_ok('/admin/users')->status_is(200);
$get->content_like(qr/User lance updated/);
$get->text_is('#user_99902 .username' => 'https://openid.camelot.uk/lancelot');
is('00', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));

done_testing();
