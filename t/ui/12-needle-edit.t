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

use File::Path qw/make_path remove_tree/;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $dir = "t/data/openqa/share/tests/opensuse/needles";
remove_tree($dir);
make_path($dir);
my @git = ('git','--git-dir', "$dir/.git",'--work-tree', $dir);
is(system(@git, 'init'), 0, "git init");
is(system(@git, 'config', 'user.email', 'openqa@examle.com'), 0, "git config email");
is(system(@git, 'config', 'user.name', 'openQA testsuite'), 0, "git config name");

my $t = Test::Mojo->new('OpenQA');

# First of all, init the session (this should probably be in OpenQA::Test)
my $req = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');

$req = $t->get_ok('/tests/99937/modules/isosize/steps/1')->status_is(200);
use Data::Dump;
select STDERR;
#dd $req->tx->res->dom;

$req->element_exists("img[src=/tests/99937/images/thumb/isosize-1.png]");
$req->element_exists("select[id=needlediff_selector]");

$req = $t->get_ok('/tests/99937/modules/isosize/steps/1/edit')->status_is(200);

$req->element_exists("img[src=/tests/99937/images/thumb/isosize-1.png]");
#$req->element_exists("input[data-url=\"/tests/99937/images/thumb/isosize-1.png\"]");
$req->element_exists("input[data-image=isosize-1.png]");

# save needle without auth must fail
$req = $t->post_ok('/tests/99937/modules/isosize/steps/1',{ 'X-CSRF-Token' => $token },form => { name => 'foo', prio => "foobar"})->status_is(403);

# log in as operator
$test_case->login($t, 'https://openid.camelot.uk/percival');

# post needle based on screenshot
my $json='{
   "area" : [ { "width" : 1024,"xpos" : 0,"type" : "match","ypos" : 0, "height" : 768 } ],
   "tags" : [  "blah"  ]
}';
$req = $t->post_ok('/tests/99937/modules/isosize/steps/1',{ 'X-CSRF-Token' => $token },form => { json => $json, imagename => 'isosize-1.png', needlename => "isosize-blah", overwrite => 'no' })->status_is(200);
$req->element_exists_not('.ui-state-error');
ok(-f "$dir/isosize-blah.png", "isosize-blah.png created");
ok(-f "$dir/isosize-blah.json", "isosize-blah.json created");
# post needle again and diallow to overwrite
$req = $t->post_ok('/tests/99937/modules/isosize/steps/1',{ 'X-CSRF-Token' => $token },form => { json => $json, imagename => 'isosize-1.png', needlename => "isosize-blah", overwrite => 'yes' })->status_is(200);
$req->text_like('.ui-state-highlight' => qr/Needle isosize-blah created/);

ok(open(GIT, '-|', @git, 'show'), "git show");
{
    local $/;
    my $commit = <GIT>;
    like($commit, qr/Author: Percival <percival\@example.com>/, "correct author in git commit");
}
close GIT;

# post needle based on existing needle, reuse the one we created in the test
# above
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => $json,
        imagename => 'isosize-blah.png',
        imagedistri => 'opensuse',
        needlename => "isosize-blub",
        overwrite => "yes"
    }
)->status_is(200);
$req->element_exists_not('.ui-state-error');

# post invalid values
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => $json,
        imagename => '../isosize-blah.png',
        imagedistri => 'ope/nsuse',
        needlename => ".isosize-blub",
        imageversion => "/"
    }
)->status_is(200);
$req->text_is('.ui-state-error' => 'Error creating/updating needle: wrong parameters imagename imagedistri imageversion needlename overwrite');

# post invalid json
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => 'blub',
        imagename => 'isosize-blah.png',
        imagedistri => 'opensuse',
        needlename => "isosize-blub",
        overwrite => "yes"
    }
)->status_is(200);
$req->text_like('.ui-state-error' => '/Error validating needle: syntax error: malformed JSON string/');

# post incomplete json i)
my $json1='{
   "area" : [ { "width" : 1024,"xpos" : 0,"type" : "match","ypos" : 0, "height" : 768 } ],
   "tags" : [  ]
}';
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => $json1,
        imagename => 'isosize-blah.png',
        imagedistri => 'opensuse',
        needlename => "isosize-blub",
        overwrite => "yes"
    }
)->status_is(200);
$req->text_is('.ui-state-error' => 'Error validating needle: no tag defined');

# post incomplete json ii)
my $json2='{
   "tags" : [  "blah"  ]
}';
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => $json2,
        imagename => 'isosize-blah.png',
        imagedistri => 'opensuse',
        needlename => "isosize-blub",
        overwrite => "yes"
    }
)->status_is(200);
$req->text_is('.ui-state-error' => 'Error validating needle: no area defined');

# post incomplete json iii)
my $json3='{
   "area" : [ { "xpos" : 0,"type" : "match","ypos" : 0, "height" : 768 } ],
   "tags" : [  "blah"  ]
}';
$req = $t->post_ok(
    '/tests/99937/modules/isosize/steps/1',
    { 'X-CSRF-Token' => $token },
    form => {
        json => $json3,
        imagename => 'isosize-blah.png',
        imagedistri => 'opensuse',
        needlename => "isosize-blub",
        overwrite => "yes"
    }
)->status_is(200);
$req->text_is('.ui-state-error' => 'Error validating needle: area without width');

#open (F, '|-', 'w3m -T text/html');
#open (F, '|-', 'w3m -dump');
#print F $req->tx->res->body;
#close F;

done_testing();
