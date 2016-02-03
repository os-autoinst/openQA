# Copyright (C) 2015 SUSE Linux GmbH
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

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 27;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

#
# List with no parameters
#

is($driver->get_title(), "openQA", "on main page");
$driver->find_element('Login', 'link_text')->click();
# we are back on the main page
is($driver->get_title(), "openQA", "back on main page");

$driver->find_element('opensuse', 'link_text')->click();

is($driver->find_element('h1:first-of-type', 'css')->get_text(), 'Last Builds for Group opensuse', "on group overview");

$driver->find_element('textarea',       'css')->send_keys('This is a cool test');
$driver->find_element('#submitComment', 'css')->click();

is($driver->find_element('h4.media-heading', 'css')->get_text(), "Demo wrote less than a minute ago", "heading");

#t::ui::PhantomTest::make_screenshot('mojoResults.png');
#print $driver->get_page_source();

is($driver->find_element('div.media-comment', 'css')->get_text(), "This is a cool test", "body");

# URL auto-replace
$driver->find_element('textarea', 'css')->send_keys('
    foo@bar foo#bar
    <a href="https://openqa.example.com/foo/bar">https://openqa.example.com/foo/bar</a>: http://localhost:9562
    https://openqa.example.com/tests/181148 (reference http://localhost/foo/bar )
    bsc#1234 boo#2345 poo#3456 t#4567
    t#5678/modules/welcome/steps/1'
);
$driver->find_element('#submitComment', 'css')->click();

my @comments = $driver->find_elements('div.media-comment p', 'css');
# the first made comment needs to be 2nd now
is($comments[1]->get_text(), 'This is a cool test');

my @urls = $driver->find_elements('div.media-comment a', 'css');
is((shift @urls)->get_text(), 'https://openqa.example.com/foo/bar',      "url1");
is((shift @urls)->get_text(), 'http://localhost:9562',                   "url2");
is((shift @urls)->get_text(), 'https://openqa.example.com/tests/181148', "url3");
is((shift @urls)->get_text(), 'http://localhost/foo/bar',                "url4");
is((shift @urls)->get_text(), 'bsc#1234',                                "url5");
is((shift @urls)->get_text(), 'boo#2345',                                "url6");
is((shift @urls)->get_text(), 'poo#3456',                                "url7");
is((shift @urls)->get_text(), 't#4567',                                  "url8");
is((shift @urls)->get_text(), 't#5678/modules/welcome/steps/1',          "url9");

my @urls2 = $driver->find_elements('div.media-comment a', 'css');
is((shift @urls2)->get_attribute('href'), 'https://openqa.example.com/foo/bar',                 "url1-href");
is((shift @urls2)->get_attribute('href'), 'http://localhost:9562/',                             "url2-href");
is((shift @urls2)->get_attribute('href'), 'https://openqa.example.com/tests/181148',            "url3-href");
is((shift @urls2)->get_attribute('href'), 'http://localhost/foo/bar',                           "url4-href");
is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234',     "url5-href");
is((shift @urls2)->get_attribute('href'), 'https://bugzilla.opensuse.org/show_bug.cgi?id=2345', "url6-href");
is((shift @urls2)->get_attribute('href'), 'https://progress.opensuse.org/issues/3456',          "url7-href");
like((shift @urls2)->get_attribute('href'), qr{/tests/4567}, "url8-href");
like((shift @urls2)->get_attribute('href'), qr{/tests/5678/modules/welcome/steps}, "url9-href");

# check commenting in test results
$driver->find_element('Build0048', 'link_text')->click();
$driver->find_element('.status',   'css')->click();
is($driver->get_title(), "openQA: opensuse-Factory-DVD-x86_64-Build0048-doc test results", "on test result page");
$driver->find_element('Comments (0)',   'link_text')->click();
$driver->find_element('textarea',       'css')->send_keys('Comments also work within test results');
$driver->find_element('#submitComment', 'css')->click();

is($driver->find_element('blockquote.ui-state-highlight', 'css')->get_text(), "Comment added", "comment added highlight");

# go back to test result overview and check comment availability sign
$driver->find_element('Build0048@opensuse', 'link_text')->click();
is($driver->get_title(), "openQA: Test summary", "back on test group overview");
t::ui::PhantomTest::kill_phantom();

done_testing();
