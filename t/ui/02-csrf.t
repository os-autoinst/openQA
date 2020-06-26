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
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

$t->get_ok('/');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');

# test cancel and restart without logging in
$t->post_ok('/api/v1/jobs/99928/cancel'       => {'X-CSRF-Token' => $token} => form => {})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/restart'      => {'X-CSRF-Token' => $token} => form => {})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/prio?prio=34' => {'X-CSRF-Token' => $token} => form => {})->status_is(403);


# Log in with an authorized user for the rest of the test
$test_case->login($t, 'percival');

$t->get_ok('/api_keys');

ok($token =~ /[0-9a-z]{40}/,                                                       "csrf token in meta tag");
ok($t->tx->res->dom->at('meta[name=csrf-param]')->attr('content') eq 'csrf_token', "csrf param in meta tag");

is($token, $t->tx->res->dom->at('form input[name=csrf_token]')->{value}, "token is the same in form");

# test cancel with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/cancel' => form => {csrf_token => 'foobar'})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/cancel' => {'X-CSRF-Token' => $token} => form => {})->status_is(200);
$t->post_ok('/api/v1/jobs/99928/cancel' => form => {csrf_token => $token})->status_is(200);

# test restart with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/restart' => form => {csrf_token => 'foobar'})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/restart' => {'X-CSRF-Token' => $token} => form => {})->status_is(200);

# test prio with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/prio?prio=33' => form => {csrf_token => 'foobar'})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/prio?prio=34' => {'X-CSRF-Token' => $token} => form => {})->status_is(200);
$t->post_ok('/api/v1/jobs/99928/prio?prio=35' => form => {csrf_token => $token})->status_is(200);

done_testing();
