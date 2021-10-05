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
# So let's login as a admin
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'arthur');
$t->get_ok('/admin/users')->status_is(200);
is($t->tx->res->dom->at('#user_99901 .role')->attr('data-order'), '11');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '00');
is($t->tx->res->dom->at('#user_99903 .role')->attr('data-order'), '01');


# Make only admin leave
$t->post_ok('/admin/users/99901', {'X-CSRF-Token' => $token} => form => {role => 'operator'})->status_is(302);
$t->get_ok('/admin/users')->status_is(403);
$t->delete_ok('/logout')->status_is(302);

# Login and claim the kingdom
$test_case->login($t, 'morgana');
$t->get_ok('/admin/users')->status_is(200);
is($t->tx->res->dom->at('#user_99901 .role')->attr('data-order'), '01');
is($t->tx->res->dom->at('#user_99902 .role')->attr('data-order'), '00');
is($t->tx->res->dom->at('#user_99903 .role')->attr('data-order'), '01');


# Leave
$t->delete_ok('/logout')->status_is(302);

# No-one else can claim the kingdom
$test_case->login($t, 'merlin');
$t->get_ok('/admin/users')->status_is(403);

done_testing();
