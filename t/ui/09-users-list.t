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
