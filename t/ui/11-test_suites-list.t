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

# First of all, init the session (this should probably be in OpenQA::Test)
my $req = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');

#
# No login, no list
$t->get_ok('/admin/test_suites')->status_is(403);

#
# Not even for operators
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'https://openid.camelot.uk/percival');
$t->get_ok('/admin/test_suites')->status_is(403);

#
# So let's login as a admin
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'https://openid.camelot.uk/arthur');
$req = $t->get_ok('/admin/test_suites')->status_is(200);

# check columns
$req->text_is('#test_suite_1013 td.name' => 'RAID0');
$req->text_is('#test_suite_1013 td.prio' => '50');
$req->element_exists('#test_suite_1013 td.variables');
# delete one variable link
$req->element_exists('#test_suite_1013 td.variables a[data-method=delete][href="/admin/test_suites/1013/33"]');

# variable combo box, value and add button
$req->element_exists("#test_suite_1013 td.variables input[type=text][name=key]");
$req->element_exists("#test_suite_1013 td.variables datalist");
$req->text_is('#test_suite_1013 td.variables datalist option:nth-child(1)' => 'BTRFS');
$req->element_exists('#test_suite_1013 td.variables input[type=text][name=value]');
$req->element_exists('#test_suite_1013 td.variables input[type=submit][value=add]');
# test suite delete button
$req->element_exists('#test_suite_1013 td.action a[data-method=delete][href="/admin/test_suites/1013"]');

$req->text_is('#test_suite_1013 td.variables' => 'DESKTOP=kde INSTALLONLY=1 RAIDLEVEL=0');

# delete a variable
$t->delete_ok('/admin/test_suites/1013/33', { 'X-CSRF-Token' => $token })->status_is(302);

$req = $t->get_ok('/admin/test_suites')->status_is(200);
$req->text_is('#test_suite_1013 td.variables' => 'INSTALLONLY=1 RAIDLEVEL=0');

# delete a test suite
$t->delete_ok('/admin/test_suites/1013', { 'X-CSRF-Token' => $token })->status_is(302);

$req = $t->get_ok('/admin/test_suites')->status_is(200);
$req->element_exists_not('td#test_suite_1013');

# add a test suite, invalid
$req = $t->post_ok('/admin/test_suites', { 'X-CSRF-Token' => $token }, form => { name => 'foo', prio => "foobar"})->status_is(200);
$req->element_exists('.ui-state-error');

# add a test suite
$req = $t->post_ok('/admin/test_suites', { 'X-CSRF-Token' => $token }, form => { name => 'foo', prio => 42})->status_is(302);

# doesn't work as the list is ordered by name ..
#$req = $t->get_ok('/admin/test_suites')->status_is(200);
#my $id = $req->tx->res->dom->at('#test-suites tbody tr:last-child')->{'id'};
#$id =~ s/test_suite_(\d+)/\1/;
#ok($id, "id returned");

$req->element_exists_not('.ui-state-error');
$req = $t->get_ok('/admin/test_suites')->status_is(200);
$req->element_exists_not('.ui-state-error');

my $id = 1031;
# we could figure it out as well
#$req->tx->res->dom->find('#test-suites tr td.name')->each(sub { my $node = shift; say $node->parent->{id} if $node->text eq 'foo'});

$req->text_is("#test_suite_$id td.name" => 'foo');
$req->text_is("#test_suite_$id td.prio" => '42');
$req->text_is("#test_suite_$id td.variables" => '');

# add variable
$t->post_ok("/admin/test_suites/$id", { 'X-CSRF-Token' => $token }, form => { key => 'DESKTOP', value => "dwarf"})->status_is(302);

$req = $t->get_ok('/admin/test_suites')->status_is(200);
$req->text_is("#test_suite_$id td.variables" => 'DESKTOP=dwarf');

done_testing();
