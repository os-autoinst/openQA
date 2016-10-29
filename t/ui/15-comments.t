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

# check 'reviewed' labels
my $get = $t->get_ok($driver->get_current_url())->status_is(200);
$get->element_exists_not('.review', 'no build is marked as \'reviewed\' as there are no comments yet');
$get->element_exists('.review-all-passed', 'exactly one build is marked as \'reviewed\' because all tests passed');

$driver->find_element('opensuse', 'link_text')->click();

is($driver->find_element('h2:first-of-type', 'css')->get_text(), 'Last Builds for Group opensuse', "on group overview");

# define test message
my $test_message             = "This is a cool test ☠";
my $another_test_message     = " - this message will be appended if editing works ☠";
my $edited_test_message      = $test_message . $another_test_message;
my $description_test_message = "pinned-description ... The description";
my $user_name                = 'Demo';

# switches to comments tab (required when editing comments in test results)
# expects the current number of comments as argument (currently the easiest way to find the tab button)
sub switch_to_comments_tab {
    my $current_comment_count = shift;
    $driver->find_element("Comments ($current_comment_count)", 'link_text')->click();
}

# checks comment heading and text for recently added comment
sub check_comment {
    my ($supposed_text, $edited) = @_;

    if ($edited) {
        is($driver->find_element('h4.media-heading', 'css')->get_text(), "$user_name wrote less than a minute ago (last edited less than a minute ago)", "heading");
    }
    else {
        is($driver->find_element('h4.media-heading', 'css')->get_text(), "$user_name wrote less than a minute ago", "heading");
    }
    is($driver->find_element('div.media-comment', 'css')->get_text(), $supposed_text, "body");
    my $anchor = $driver->find_element('h4.media-heading .comment-anchor', 'css')->get_attribute('href');
    $anchor =~ s/[^#]*#/#/;
    like($anchor, qr/#comment-[0-9]+/, "anchor matches expected format");
    is($driver->find_element("$anchor div.media-comment", 'css')->get_text(), $supposed_text, "body by anchor ref");
}

# tests adding, editing and removing comments
sub test_comment_editing {
    my ($in_test_results) = @_;

    my @comments = $driver->find_elements('div.media-comment', 'css');
    is(scalar @comments, 0, 'no comments present so far');

    subtest 'add' => sub {
        $driver->find_element('#text',          'css')->send_keys($test_message);
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;

        if ($in_test_results) {
            switch_to_comments_tab(1);
        }

        check_comment($test_message, 0);
    };

    subtest 'edit' => sub {
        $driver->find_element('button.trigger-edit-button', 'css')->click();
        # wait 1 second to ensure initial time and last update time differ
        sleep 1;

        # try to edit the first displayed comment (the one which has just been added)
        $driver->find_element('textarea.comment-editing-control', 'css')->send_keys($another_test_message);
        $driver->find_element('button.comment-editing-control',   'css')->click();
        t::ui::PhantomTest::wait_for_ajax;

        if ($in_test_results) {
            switch_to_comments_tab(1);
        }

        # check whether the changeings have been applied
        check_comment($edited_test_message, 1);
    };

    subtest 'remove' => sub {
        # try to remove the first displayed comment (wthe one which has just been edited)
        $driver->find_element('button.remove-edit-button', 'css')->click();

        # check confirmation and dismiss in the first place
        $driver->execute_script("window.confirm = function() { return false; }");

        # the comment musn't be deleted yet
        is($driver->find_element('div.media-comment', 'css')->get_text(), $edited_test_message, "comment is still there after dismissing removal");

        # try to remove the first displayed comment again (and accept this time);
        $driver->execute_script("window.confirm = function() { return true; };");
        $driver->find_element('button.remove-edit-button', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;

        # check whether the comment is gone
        my @comments = $driver->find_elements('div.media-comment', 'css');
        is(scalar @comments, 0, 'removed comment is actually gone');

        if ($in_test_results) {
            switch_to_comments_tab(0);
        }

        # re-add a comment with the original message
        $driver->find_element('#text',          'css')->send_keys($test_message);
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;

        # check whether heading and comment text is displayed correctly
        if ($in_test_results) {
            switch_to_comments_tab(1);
        }

        check_comment($test_message, 0);
    };
}

subtest 'commenting in the group overview' => sub {
    test_comment_editing(0);
};

subtest 'URL auto-replace' => sub {
    $driver->find_element('#text', 'css')->send_keys('
        foo@bar foo#bar should not be detected as bugref
        bsc#2436346bla should not be detected, too
        bsc#2436347bla2
        <a href="https://openqa.example.com/foo/bar">https://openqa.example.com/foo/bar</a>: http://localhost:9562
        https://openqa.example.com/tests/181148 (reference http://localhost/foo/bar )
        bsc#1234 boo#2345,poo#3456 t#4567
        t#5678/modules/welcome/steps/1
        https://progress.opensuse.org/issues/6789
        https://bugzilla.novell.com/show_bug.cgi?id=7890
        [bsc#1000629](https://bugzilla.suse.com/show_bug.cgi?id=1000629)
        <a href="https://bugzilla.suse.com/show_bug.cgi?id=1000630">bsc#1000630</a>
        bnc#1246
        gh#os-autoinst/openQA#1234
        https://github.com/os-autoinst/os-autoinst/pull/960'
    );
    $driver->find_element('#submitComment', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;

    # the first made comment needs to be 2nd now
    my @comments = $driver->find_elements('div.media-comment p', 'css');
    #is($comments[0]->get_text(), $test_message, "body of first comment after adding another");

    like($comments[0]->get_text(), qr/bsc#1234 boo#2345,poo#3456 t#4567 .*poo#6789 bsc#7890 bsc#1000629 bsc#1000630/);
    my @urls = $driver->find_elements('div.media-comment a', 'css');
    is(scalar @urls, 16);
    is((shift @urls)->get_text(), 'https://openqa.example.com/foo/bar',      "url1");
    is((shift @urls)->get_text(), 'http://localhost:9562',                   "url2");
    is((shift @urls)->get_text(), 'https://openqa.example.com/tests/181148', "url3");
    is((shift @urls)->get_text(), 'http://localhost/foo/bar',                "url4");
    is((shift @urls)->get_text(), 'bsc#1234',                                "url5");
    is((shift @urls)->get_text(), 'boo#2345',                                "url6");
    is((shift @urls)->get_text(), 'poo#3456',                                "url7");
    is((shift @urls)->get_text(), 't#4567',                                  "url8");
    is((shift @urls)->get_text(), 't#5678/modules/welcome/steps/1',          "url9");
    is((shift @urls)->get_text(), 'poo#6789',                                "url10");
    is((shift @urls)->get_text(), 'bsc#7890',                                "url11");
    is((shift @urls)->get_text(), 'bsc#1000629',                             "url12");
    is((shift @urls)->get_text(), 'bsc#1000630',                             "url13");
    is((shift @urls)->get_text(), 'bnc#1246',                                "url14");
    is((shift @urls)->get_text(), 'gh#os-autoinst/openQA#1234',              "url15");
    is((shift @urls)->get_text(), 'gh#os-autoinst/os-autoinst#960',          "url16");

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
    is((shift @urls2)->get_attribute('href'), 'https://progress.opensuse.org/issues/6789',             "url10-href");
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=7890',        "url11-href");
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1000629',     "url12-href");
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1000630',     "url13-href");
    is((shift @urls2)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1246',        "url14-href");
    is((shift @urls2)->get_attribute('href'), 'https://github.com/os-autoinst/openQA/issues/1234',     "url15-href");
    is((shift @urls2)->get_attribute('href'), 'https://github.com/os-autoinst/os-autoinst/issues/960', "url16-href");
};

subtest 'commenting in test results including labels' => sub {

    # navigate to comments tab of test result page
    $driver->find_element('Job Groups', 'link_text')->click();
    $driver->find_element('Build0048',  'link_text')->click();
    $driver->find_element('.status',    'css')->click();
    is($driver->get_title(), 'openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results', "on test result page");
    switch_to_comments_tab(0);

    # do the same tests for comments as in the group overview
    test_comment_editing(1);

    $driver->find_element('#text',          'css')->send_keys($test_message);
    $driver->find_element('#submitComment', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;

    subtest 'check comment availability sign on test result overview' => sub {
        $driver->find_element('Job Groups', 'link_text')->click();
        like($driver->find_element('#current-build-overview', 'css')->get_text(), qr/\QBuild 0048\E/, 'on the right build');
        $driver->find_element('#current-build-overview a', 'css')->click();

        is($driver->get_title(), "openQA: Test summary", "back on test group overview");
        is($driver->find_element('#res_DVD_x86_64_doc .fa-comment', 'css')->get_attribute('title'), '2 comments available', "test results show available comment(s)");
    };

    subtest 'add label and bug and check availability sign' => sub {
        $driver->get($baseurl . 'tests/99938#comments');
        $driver->find_element('#text',          'css')->send_keys('label:true_positive');
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        $driver->find_element('Job Groups',                'link_text')->click();
        $driver->find_element('#current-build-overview a', 'css')->click();
        is($driver->find_element('#res_DVD_x86_64_doc .fa-bookmark', 'css')->get_attribute('title'), 'true_positive', 'label icon shown');
        $driver->get($baseurl . 'tests/99938#comments');
        $driver->find_element('#text',          'css')->send_keys('bsc#1234');
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        $driver->find_element('Job Groups',                'link_text')->click();
        $driver->find_element('#current-build-overview a', 'css')->click();
        is($driver->find_element('#res_DVD_x86_64_doc .fa-bug', 'css')->get_attribute('title'), 'Bug(s) referenced: bsc#1234', 'bug icon shown');
        my @labels = $driver->find_elements('#res_DVD_x86_64_doc .test-label', 'css');
        is(scalar @labels, 1, 'Only one label is shown at a time');
        $get = $t->get_ok($driver->get_current_url())->status_is(200);
        is($get->tx->res->dom->at('#res_DVD_x86_64_doc .fa-bug')->parent->{href}, 'https://bugzilla.suse.com/show_bug.cgi?id=1234');
        $driver->find_element('opensuse', 'link_text')->click();
        is($driver->find_element('.review-all-passed', 'css')->get_attribute('title'), 'Reviewed (all passed)', 'build should be marked because all tests passed');
        is($driver->find_element('.review',            'css')->get_attribute('title'), 'Reviewed (1 comments)', 'build should be marked as labeled');

        subtest 'progress items work, too' => sub {
            $driver->get($baseurl . 'tests/99926#comments');
            $driver->find_element('#text',          'css')->send_keys('poo#9876');
            $driver->find_element('#submitComment', 'css')->click();
            t::ui::PhantomTest::wait_for_ajax;
            $driver->find_element('Job Groups', 'link_text')->click();
            like($driver->find_element('#current-build-overview', 'css')->get_text(), qr/\QBuild 87.5011\E/, 'on the right build');
            $driver->find_element('#current-build-overview a', 'css')->click();
            is($driver->find_element('#res_staging_e_x86_64_minimalx .fa-bolt', 'css')->get_attribute('title'), 'Bug(s) referenced: poo#9876', 'bolt icon shown for progress issues');
        };

        subtest 'latest bugref but first in each comment' => sub {
            $driver->get($baseurl . 'tests/99926#comments');
            $driver->find_element('#text',          'css')->send_keys('poo#9875 poo#9874');
            $driver->find_element('#submitComment', 'css')->click();
            t::ui::PhantomTest::wait_for_ajax;
            $driver->find_element('Job Groups', 'link_text')->click();
            like($driver->find_element('#current-build-overview', 'css')->get_text(), qr/\QBuild 87.5011\E/, 'on the right build');
            $driver->find_element('#current-build-overview a', 'css')->click();
            my $bugref = $driver->find_element('#res_staging_e_x86_64_minimalx .fa-bolt', 'css');
            is($bugref->get_attribute('title'), 'Bug(s) referenced: poo#9875', 'first bugref in latest comment wins');
            $get = $t->get_ok($driver->get_current_url())->status_is(200);
            is($get->tx->res->dom->at('#res_staging_e_x86_64_minimalx .fa-bolt')->parent->{href}, 'https://progress.opensuse.org/issues/9875');
        };

        $driver->find_element('opensuse', 'link_text')->click();
    };
};

subtest 'editing when logged in as regular user' => sub {
    sub no_edit_no_remove_on_other_comments_expected {
        is(@{$driver->find_elements('button.trigger-edit-button', 'css')}, 0, "edit not displayed for other users comments");
        is(@{$driver->find_elements('button.remove-edit-button',  'css')}, 0, "removal not displayed for regular user");
    }
    sub only_edit_for_own_comments_expected {
        is(@{$driver->find_elements('button.trigger-edit-button', 'css')}, 1, "own comments can be edited");
        is(@{$driver->find_elements('button.remove-edit-button',  'css')}, 0, "no comments can be removed, even not own");
    }

    subtest 'test pinned comments' => sub {
        $driver->get($baseurl . 'group_overview/1001');
        $driver->find_element('#text',          'css')->send_keys($description_test_message);
        $driver->find_element('#submitComment', 'css')->click();
        # need to reload the page for the pinning to take effect
        # waiting for AJAX is required though to eliminate race condition
        t::ui::PhantomTest::wait_for_ajax;
        $driver->get($baseurl . 'group_overview/1001');
        is($driver->find_element('#group_descriptions .media-comment', 'css')->get_text(), $description_test_message, 'comment is pinned');
    };

    $driver->get($baseurl . 'login?user=nobody');
    subtest 'test results' => sub {
        $driver->get($baseurl . 'tests/99938#comments');
        no_edit_no_remove_on_other_comments_expected;
        $driver->find_element('#text',          'css')->send_keys('test by nobody');
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        switch_to_comments_tab(5);
        only_edit_for_own_comments_expected;
    };

    subtest 'group overview' => sub {
        $driver->get($baseurl . 'group_overview/1001');
        no_edit_no_remove_on_other_comments_expected;
        $driver->find_element('#text',          'css')->send_keys('test by nobody');
        $driver->find_element('#submitComment', 'css')->click();
        t::ui::PhantomTest::wait_for_ajax;
        only_edit_for_own_comments_expected;

        # pinned comments are not shown (pinning is only possible when commentator is operator)
        $driver->find_element('#text',          'css')->send_keys($description_test_message);
        $driver->find_element('#submitComment', 'css')->click();
        $driver->get($baseurl . 'group_overview/1001');
        my @comments = $driver->find_elements('.pinned-comment-row', 'css');
        is(scalar @comments, 1, 'there shouldn\'t appear more pinned comments');
    };
};

t::ui::PhantomTest::kill_phantom();

done_testing();
