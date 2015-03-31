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
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

# First of all, init the session (this should probably be in OpenQA::Test)
my $req   = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');

#
# So let's login as a admin
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'arthur');
my $get = $t->get_ok('/admin/users')->status_is(200);
is('11', $t->tx->res->dom->at('#user_99901 .role')->attr('data-order'));
is('00', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));
is('01', $t->tx->res->dom->at('#user_99903 .role')->attr('data-order'));


# Make only admin leave
$t->post_ok('/admin/users/99901', {'X-CSRF-Token' => $token} => form => {role => 'operator'})->status_is(302);
$get = $t->get_ok('/admin/users')->status_is(403);
$t->delete_ok('/logout')->status_is(302);

# Login and claim the kingdom
$test_case->login($t, 'morgana');
$get = $t->get_ok('/admin/users')->status_is(200);
is('01', $t->tx->res->dom->at('#user_99901 .role')->attr('data-order'));
is('00', $t->tx->res->dom->at('#user_99902 .role')->attr('data-order'));
is('01', $t->tx->res->dom->at('#user_99903 .role')->attr('data-order'));


# Leave
$t->delete_ok('/logout')->status_is(302);

# No-one else can claim the kingdom
$test_case->login($t, 'merlin');
$get = $t->get_ok('/admin/users')->status_is(403);

done_testing();
