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
use Data::Dumper;
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');
my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 29;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

my $baseurl = $driver->get_current_url();
my $get = $t->ua->get('/session/new');
my $token = $get->res->dom->at('meta[name=csrf-token]')->attr('content');

ok($token =~ /[0-9a-z]{40}/, "csrf token in meta tag");
ok($get->res->dom->at('meta[name=csrf-param]')->attr('content') eq 'csrf_token', "csrf param in meta tag");
#say "csrf token is $token";

is($token, $get->res->dom->at('form input[name=csrf_token]')->{value}, "token is the same in form");

# look for the cancel link without logging in
$driver->get($baseurl . 'tests');
ok(!@{$driver->find_elements('#scheduled #job_99928 a.api-cancel', 'css')}, 'cancel button should not exists');

# test cancel and restart without logging in
$t->post_ok('/api/v1/jobs/99928/cancel' => { 'X-CSRF-Token' => $token } => form => {})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/restart' => { 'X-CSRF-Token' => $token } => form => {})->status_is(403);
$t->post_ok('/api/v1/jobs/99928/prio?prio=34' => { 'X-CSRF-Token' => $token } => form => {})->status_is(403);


# Log in with an authorized user for the rest of the test
$test_case->login($t, 'percival');

# Test 99928 is scheduled, so can be canceled. Make sure link contains data-method=post
$driver->get($baseurl . 'tests');
ok($driver->find_element('#scheduled #job_99928 a.api-cancel[data-method="POST"]', 'css'), 'cancel button exists');

# test cancel with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/cancel' => form => { csrf_token => 'foobar' })->status_is(403);
$t->post_ok('/api/v1/jobs/99928/cancel' => { 'X-CSRF-Token' => $token } => form => {})->status_is(200);
$t->post_ok('/api/v1/jobs/99928/cancel' => form => { csrf_token => $token })->status_is(200);

# test restart with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/restart' => form => { csrf_token => 'foobar' })->status_is(403);
$t->post_ok('/api/v1/jobs/99928/restart' => { 'X-CSRF-Token' => $token } => form => {})->status_is(200);
$t->post_ok('/api/v1/jobs/99928/restart' => form => { csrf_token => $token })->status_is(200);

# test prio with and without CSRF token
$t->post_ok('/api/v1/jobs/99928/prio?prio=33' => form => { csrf_token => 'foobar' })->status_is(403);
$t->post_ok('/api/v1/jobs/99928/prio?prio=34' => { 'X-CSRF-Token' => $token } => form => {})->status_is(200);
$t->post_ok('/api/v1/jobs/99928/prio?prio=35' => form => { csrf_token => $token })->status_is(200);

t::ui::PhantomTest::kill_phantom();
done_testing();
