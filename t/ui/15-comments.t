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
use Test::Warnings;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = t::ui::PhantomTest::call_phantom();

unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

#
# List with no parameters
#
is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();
$driver->find_element('Login', 'link_text')->click();
# we are back on the main page
is($driver->get_title(), "openQA", "back on main page");

# make sure no build is marked as 'reviewed' as there are no comments yet
my $get = $t->get_ok($driver->get_current_url())->status_is(200);
$get->element_exists_not('.fa-certificate');

$driver->find_element('opensuse', 'link_text')->click();

is($driver->find_element('h1:first-of-type', 'css')->get_text(), 'Last Builds for Group opensuse', "on group overview");

# disable warning about printing UTF-8 characters
binmode STDOUT, ':utf8';

# define test message with UTF-8 character
my $test_message = "This is a cool test";
my $another_test_message = " - this message will be appended if editing works";
my $edited_test_message = $test_message . $another_test_message;

# submit a comment in the group overview
$driver->find_element('#text',          'css')->send_keys($test_message);
$driver->find_element('#submitComment', 'css')->click();

# check whether heading and comment text is displayed correctly
is($driver->find_element('h4.media-heading',  'css')->get_text(), "Demo wrote less than a minute ago", "heading");
is($driver->find_element('div.media-comment', 'css')->get_text(), $test_message, "body");

# trigger editor
$driver->find_element('button.trigger-edit-button',       'css')->click();

# wait 1 second to ensure initial time and last update time differ
sleep 1;

# try to edit the first displayed comment (the one which has just been added)
$driver->find_element('textarea.comment-editing-control', 'css')->send_keys($another_test_message);
$driver->find_element('button.comment-editing-control',   'css')->click();

# check whether the changeings have been applied
is($driver->find_element('h4.media-heading', 'css')->get_text(), "Demo wrote less than a minute ago (last edited less than a minute ago)", "heading after editing");
is($driver->find_element('div.media-comment', 'css')->get_text(), $edited_test_message, "body after editing");

# try to remove the first displayed comment (wthe one which has just been edited)
$driver->find_element('button.remove-edit-button', 'css')->click();

# check confirmation and dismiss in the first place
# FIXME: simulate dismiss, $driver->dismiss_alert and get_alert_text don't work
$driver->execute_script("window.confirm = function() { return false; }");
#is($driver->get_alert_text, "Do you really want to delete the comment written by Demo?", "confirmation is shown before removal");
#$driver->dismiss_alert;

# the comment musn't be deleted yet
is($driver->find_element('div.media-comment', 'css')->get_text(), $edited_test_message, "comment is still there after dismissing removal");

# try to remove the first displayed comment again (and accept this time);
# FIXME: simulate acception, $driver->accept_alert doesn't work
$driver->execute_script("window.confirm = function() { return true; };");
$driver->find_element('button.remove-edit-button', 'css')->click();
##$driver->accept_alert;

# check whether the comment is gone
my @comments = $driver->find_elements('div.media-comment', 'css');
is(scalar @comments, 0, "removed comment is actually gone");

# re-add a comment with the original message
$driver->find_element('#text',          'css')->send_keys($test_message);
$driver->find_element('#submitComment', 'css')->click();

# check whether heading and comment text is displayed correctly
is($driver->find_element('h4.media-heading',  'css')->get_text(), "Demo wrote less than a minute ago", "heading after re-adding");
is($driver->find_element('div.media-comment', 'css')->get_text(), $test_message, "body after re-adding");

# TODO: check whether only admins can remove comments
# TODO: check whether only own comments can be edited

# URL auto-replace
$driver->find_element('#text', 'css')->send_keys('
    foo@bar foo#bar
    <a href="https://openqa.example.com/foo/bar">https://openqa.example.com/foo/bar</a>: http://localhost:9562
    https://openqa.example.com/tests/181148 (reference http://localhost/foo/bar )
    bsc#1234 boo#2345 poo#3456 t#4567
    t#5678/modules/welcome/steps/1'
);
$driver->find_element('#submitComment', 'css')->click();

# the first made comment needs to be 2nd now
@comments = $driver->find_elements('div.media-comment p', 'css');
is($comments[1]->get_text(), $test_message, "body of first comment after adding another");

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
$driver->find_element('#text',          'css')->send_keys($test_message);
$driver->find_element('#submitComment', 'css')->click();

# check whether flash appears
is($driver->find_element('blockquote.ui-state-highlight', 'css')->get_text(), "Comment added", "comment added highlight");

# TODO: Do the same tests for editable comments in the test results as in the group overview.

# go back to test result overview and check comment availability sign
$driver->find_element('Build0048@opensuse', 'link_text')->click();
is($driver->get_title(), "openQA: Test summary", "back on test group overview");
is($driver->find_element('#res_DVD_x86_64_doc .fa-comment', 'css')->get_attribute('title'), '1 comment available', "test results show available comment(s)");

# add label and bug and check availability sign
$driver->get($baseurl . 'tests/99938#comments');
$driver->find_element('#text',              'css')->send_keys('label:true_positive');
$driver->find_element('#submitComment',     'css')->click();
$driver->find_element('Build0048@opensuse', 'link_text')->click();
is($driver->find_element('#res_DVD_x86_64_doc .fa-bookmark', 'css')->get_attribute('title'), 'true_positive', 'label icon shown');
$driver->get($baseurl . 'tests/99938#comments');
$driver->find_element('#text',              'css')->send_keys('bsc#1234');
$driver->find_element('#submitComment',     'css')->click();
$driver->find_element('Build0048@opensuse', 'link_text')->click();
is($driver->find_element('#res_DVD_x86_64_doc .fa-bug', 'css')->get_attribute('title'), 'Bug(s) referenced: bsc#1234', 'bug icon shown');
my @labels = $driver->find_elements('#res_DVD_x86_64_doc .test-label', 'css');
is(scalar @labels, 1, 'Only one label is shown at a time');
$get = $t->get_ok($driver->get_current_url())->status_is(200);
is($get->tx->res->dom->at('#res_DVD_x86_64_doc .fa-bug')->parent->{href}, 'https://bugzilla.suse.com/show_bug.cgi?id=1234');
$driver->find_element('opensuse', 'link_text')->click();
is($driver->find_element('.fa-certificate', 'css')->get_attribute('title'), 'Reviewed (1 comments)', 'build should be marked as labeled');

t::ui::PhantomTest::kill_phantom();

done_testing();
