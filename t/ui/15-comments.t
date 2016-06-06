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
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

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

# define test message
my $test_message         = "This is a cool test ☠";
my $another_test_message = " - this message will be appended if editing works ☠";
my $edited_test_message  = $test_message . $another_test_message;
my $user_name            = 'Demo';

# switches to comments tab (required when editing comments in test results)
# expects the current number of comments as argument (currently the easiest way to find the tab button)
sub switch_to_comments_tab {
    my $current_comment_count = shift;
    $driver->find_element("Comments ($current_comment_count)", 'link_text')->click();
}

# checks comment heading and text for recently added comment
sub check_comment {
    my $supposed_text = shift;
    my $edited        = shift;
    if ($edited) {
        is($driver->find_element('h4.media-heading', 'css')->get_text(), "$user_name wrote less than a minute ago (last edited less than a minute ago)", "heading");
    }
    else {
        is($driver->find_element('h4.media-heading', 'css')->get_text(), "$user_name wrote less than a minute ago", "heading");
    }
    is($driver->find_element('div.media-comment', 'css')->get_text(), $supposed_text, "body");
}

# tests adding, editing and removing comments
sub test_comment_editing {
    my $in_test_results = shift;

    # submit a comment
    $driver->find_element('#text',          'css')->send_keys($test_message);
    $driver->find_element('#submitComment', 'css')->click();

    # check whether flash appears
    is($driver->find_element('#flash-messages .alert-info span', 'css')->get_text(), "Comment added", "comment added highlight");

    if ($in_test_results) {
        switch_to_comments_tab(1);
    }

    check_comment($test_message, 0);

    # trigger editor
    $driver->find_element('button.trigger-edit-button', 'css')->click();

    # wait 1 second to ensure initial time and last update time differ
    sleep 1;

    # try to edit the first displayed comment (the one which has just been added)
    $driver->find_element('textarea.comment-editing-control', 'css')->send_keys($another_test_message);
    $driver->find_element('button.comment-editing-control',   'css')->click();

    # check whether flash appears
    is($driver->find_element('#flash-messages .alert-info span', 'css')->get_text(), "Comment changed", "comment changed highlight");

    if ($in_test_results) {
        switch_to_comments_tab(1);
    }

    # check whether the changeings have been applied
    check_comment($edited_test_message, 1);

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
    #$driver->accept_alert;

    # check whether flash appears
    is($driver->find_element('#flash-messages .alert-info span', 'css')->get_text(), "Comment removed", "comment removed highlight");

    # check whether the comment is gone
    my @comments = $driver->find_elements('div.media-comment', 'css');
    is(scalar @comments, 0, "removed comment is actually gone");

    if ($in_test_results) {
        switch_to_comments_tab(0);
    }

    # re-add a comment with the original message
    $driver->find_element('#text',          'css')->send_keys($test_message);
    $driver->find_element('#submitComment', 'css')->click();

    # check whether heading and comment text is displayed correctly
    if ($in_test_results) {
        switch_to_comments_tab(1);
    }

    check_comment($test_message, 0);
}

#
# check commenting in the group overview
#

test_comment_editing(0);

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
my @comments = $driver->find_elements('div.media-comment p', 'css');
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

#
# check commenting in test results
#

# navigate to comments tab of test result page
$driver->find_element('Build0048', 'link_text')->click();
$driver->find_element('.status',   'css')->click();
is($driver->get_title(), "openQA: opensuse-Factory-DVD-x86_64-Build0048-doc test results", "on test result page");
switch_to_comments_tab(0);

# do the same tests for comments as in the group overview
test_comment_editing(1);

$driver->find_element('#text',          'css')->send_keys($test_message);
$driver->find_element('#submitComment', 'css')->click();

# go back to test result overview and check comment availability sign
$driver->find_element('Build0048@opensuse', 'link_text')->click();
is($driver->get_title(), "openQA: Test summary", "back on test group overview");
is($driver->find_element('#res_DVD_x86_64_doc .fa-comment', 'css')->get_attribute('title'), '2 comments available', "test results show available comment(s)");

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
$driver->get($baseurl . 'tests/99926#comments');
$driver->find_element('#text',                 'css')->send_keys('poo#9876');
$driver->find_element('#submitComment',        'css')->click();
$driver->find_element('Build87.5011@opensuse', 'link_text')->click();
is($driver->find_element('#res_staging_e_x86_64_minimalx .fa-bolt', 'css')->get_attribute('title'), 'Bug(s) referenced: poo#9876', 'bolt icon shown for progress issues');
$driver->find_element('opensuse', 'link_text')->click();

#
# do tests for editing when logged in as regular user(group overview)
#

# TODO: login as another user which is no admin

sub test_comment_editing_as_regular_user {
    # TODO: check whether removal of comments is possible (should not be possible)

    # the removal button shouldn't be displayed when not logged in as admin
    is(@{$driver->find_elements('button.remove-edit-button', 'css')}, 0, "removal not displayed for regular user");

    # TODO: check whether only own comments can be edited
}

#test_comment_editing_as_regular_user;

#
# do tests for editing when logged in as regular user (test results)
#

# navigate to test results (again)
$driver->find_element('Build0048', 'link_text')->click();
$driver->find_element('.status',   'css')->click();
is($driver->get_title(), "openQA: opensuse-Factory-DVD-x86_64-Build0048-doc test results", "on test result page");
switch_to_comments_tab(4);

#test_comment_editing_as_regular_user;

t::ui::PhantomTest::kill_phantom();

done_testing();
