#! /usr/bin/perl

# Copyright (C) 2014-2018 SUSE LLC
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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use Mojo::JSON qw(decode_json encode_json);
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Module::Load::Conditional qw(can_load);

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use OpenQA::SeleniumTest;

sub schema_hook {
    my $schema = OpenQA::Test::Database->new->create;
    my $jobs   = $schema->resultset('Jobs');

    # set assigned_worker_id to test whether worker still displayed when job set to done
    # manually for PhantomJS test
    $jobs->find(99963)->update({assigned_worker_id => 1});

}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}
my $baseurl = $driver->get_current_url;

# returns the contents of the candidates combo box as hash (key: tag, value: array of needle names)
sub find_candidate_needles {
    # ensure the candidates menu is visible
    my @candidates_menus = $driver->find_elements('#candidatesMenu');
    is(scalar @candidates_menus, 1, 'exactly one candidates menu present at a time');
    $candidates_menus[0]->click();

    # read the tags/needles from the HTML strucutre
    my @section_elements = $driver->find_elements('#needlediff_selector ul table');
    my %needles_by_tag   = map {
        # find tag name
        my @tag_elements = $driver->find_child_elements($_, 'thead > tr');
        is(scalar @tag_elements, 1, 'exactly one tag header present' . "\n");

        # find needle names
        my @needles;
        my @needle_elements = $driver->find_child_elements($_, 'tbody > tr');
        for my $needle_element (@needle_elements) {
            my @needle_parts = $driver->find_child_elements($needle_element, 'td');
            next unless @needle_parts;

            is(scalar @needle_parts, 3, 'exactly three parts per needle present (percentage, name, diff buttons)');
            push(@needles,
                    OpenQA::Test::Case::trim_whitespace($needle_parts[0]->get_text()) . '%: '
                  . OpenQA::Test::Case::trim_whitespace($needle_parts[1]->get_text()));
        }

        OpenQA::Test::Case::trim_whitespace($tag_elements[0]->get_text()) => \@needles;
    } @section_elements;

    # further assertions
    my $selected_needle_count = scalar @{$driver->find_elements('#needlediff_selector tr.selected')};
    ok($selected_needle_count <= 1, "at most one needle is selected at a time ($selected_needle_count selected)");

    # close the candidates menu again, return results
    $driver->find_element('#candidatesMenu')->click();
    return \%needles_by_tag;
}

$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

$driver->get("/tests/99946");
$driver->title_is('openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results', 'tests/99946 followed');

$driver->find_element_by_link_text('installer_timezone')->click();
like(
    $driver->get_current_url(),
    qr{.*/tests/99946/modules/installer_timezone/steps/1/src$},
    "on src page for installer_timezone test"
);

is($driver->find_element('.cm-comment')->get_text(), '#!/usr/bin/perl -w', "we have a perl comment");

$driver->get("/tests/99937");
disable_bootstrap_animations;
sub current_tab {
    return $driver->find_element('.nav.nav-tabs .active')->get_text;
}
is(current_tab, 'Details', 'starting on Details tab for completed job');
$driver->find_element_by_link_text('Settings')->click();
is(current_tab, 'Settings', 'switched to settings tab');
$driver->go_back();
is(current_tab, 'Details', 'back to details tab');

$driver->find_element('[title="wait_serial"]')->click();
wait_for_ajax;
ok($driver->find_element_by_id('preview_container_out')->is_displayed(), "preview window opens on click");
like(
    $driver->find_element_by_id('preview_container_in')->get_text(),
    qr/wait_serial expected/,
    "Preview text with wait_serial output shown"
);
like($driver->get_current_url(), qr/#step/, "current url contains #step hash");
$driver->find_element('[title="wait_serial"]')->click();
ok($driver->find_element_by_id('preview_container_out')->is_hidden(), "preview window closed after clicking again");
unlike($driver->get_current_url(), qr/#step/, "current url doesn't contain #step hash anymore");

$driver->find_element('[href="#step/bootloader/1"]')->click();
wait_for_ajax;
is_deeply(find_candidate_needles, {'inst-bootmenu' => []}, 'correct tags displayed');

sub check_report_links {
    my ($failed_module, $failed_step) = @_;

    my @report_links = $driver->find_elements('#preview_container_in .report', 'css');
    my @title        = map { $_->get_attribute('title') } @report_links;
    is($title[0], 'Report product bug', 'product bug report URL available');
    is($title[1], 'Report test issue',  'test issue report URL available');
    my @url = map { $_->get_attribute('href') } @report_links;
    like($url[0], qr{bugzilla.*enter_bug.*tests%2F99937},        'bugzilla link referencing current test');
    like($url[0], qr{in\+scenario\+opensuse-13\.1-DVD-i586-kde}, 'bugzilla link contains scenario');
    like($url[1], qr{progress.*new},                             'progress/redmine link for reporting test issues');
    like($url[1], qr{in\+scenario\+opensuse-13\.1-DVD-i586-kde}, 'progress/redmine link contains scenario');
    like(
        $url[1],
        qr{in.*$failed_module.*$failed_module%2Fsteps%2F$failed_step},
        'progress/redmine link refers to right module/step'
    );
}

subtest 'bug reporting' => sub {
    subtest 'screenshot' => sub {
        # note: image of bootloader step from previous test 'correct tags displayed' is still shown
        check_report_links(bootloader => 1);
    };

    subtest 'text output' => sub {
        $driver->find_element('[href="#step/sshfs/2"]')->click();
        wait_for_ajax;
        check_report_links(sshfs => 2);
    };
};

# test running view with Test::Mojo as phantomjs would get stuck on the
# liveview/livelog forever
my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $get = $t->get_ok($baseurl . 'tests/99963')->status_is(200);

my @worker_text = $get->tx->res->dom->find('#assigned-worker')->map('all_text')->each;
like($worker_text[0], qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/, 'worker displayed when job running');
my @worker_href = $get->tx->res->dom->find('#assigned-worker a')->map(attr => 'href')->each;
is($worker_href[0], '/admin/workers/1', 'link to worker correct');
my @scenario_description = $get->tx->res->dom->find('#scenario-description')->map('all_text')->each;
like(
    $scenario_description[0],
    qr/[ \n]*Simple kde test, before advanced_kde[ \n]*/,
    'scenario description is displayed'
);

$t->element_count_is('.tab-pane.active', 1, 'only one tab visible at the same time when using step url');

my $href_to_isosize = $t->tx->res->dom->at('.component a[href*=installer_timezone]')->{href};
$t->get_ok($baseurl . ($href_to_isosize =~ s@^/@@r))->status_is(200);

subtest 'render bugref links in thumbnail text windows' => sub {
    $driver->get('/tests/99946');
    $driver->find_element('[title="Soft Failed"]')->click();
    wait_for_ajax;
    is(
        $driver->find_element_by_id('preview_container_in')->get_text(),
        'Test bugref bsc#1234 https://fate.suse.com/321208',
        'bugref text correct'
    );
    my @a = $driver->find_elements('#preview_container_in pre a', 'css');
    is((shift @a)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bugref href correct');
    is((shift @a)->get_attribute('href'), 'https://fate.suse.com/321208', 'regular href correct');
};

subtest 'render text results' => sub {
    $driver->get('/tests/99946');

    # select a text result
    $driver->find_element('[title="Some text result from external parser"]')->click();
    like($driver->get_current_url(), qr/#step\/logpackages\/6/, 'url contains step');
    is(
        $driver->find_element('.current_preview .resborder')->get_text(),
        'This is a dummy result to test rendering text results from external parsers.',
        'text result rendered correctly'
    );

    # select another text result
    $driver->find_element('[title="Another text result from external parser"]')->click();
    like($driver->get_current_url(), qr/#step\/logpackages\/7/, 'url contains step');
    my @lines = split(/\n/, $driver->find_element('.current_preview .resborder')->get_text());
    is(scalar @lines, 11, 'correct number of lines');

    # unselecting text result
    $driver->find_element('[title="Another text result from external parser"]')->click();
    unlike($driver->get_current_url(), qr/#step/, 'step removed from url');

    # check whether other text results (not parser output) are unaffected
    $driver->find_element('[title="One more text result"]')->click();
    wait_for_ajax;
    is(
        $driver->find_element_by_id('preview_container_in')->get_text(),
        "But this one doesn't come from parser so\nit should not be displayed in a special way.",
        'text results not from parser shown in ordinary preview container'
    );
# note: check whether the softfailure is unaffected is already done in subtest 'render bugref links in thumbnail text windows'

    subtest 'external table' => sub {
        my $external_table = $driver->find_element_by_id('external-table');
        is($external_table->is_displayed(), 0, 'external table not visible by default');
        $driver->find_element_by_link_text('External results')->click();
        is($external_table->is_displayed(), 1, 'external table visible after clicking its tab header');
        my @rows = $driver->find_child_elements($external_table, 'tr');
        is(scalar @rows, 3, 'external table has 3 rows (heading and 2 results)');
        my $res1
          = 'logpackages Some text result from external parser This is a dummy result to test rendering text results from external parsers.';
        my $res2
          = qr/logpackages Another text result from external parser Another dummy result to test rendering text results from external parsers\..*/;
        is($rows[1]->get_text(), $res1, 'first result displayed');
        like($rows[2]->get_text(), $res2, 'second result displayed');

        $driver->find_element_by_id('external-only-failed-filter')->click();
        @rows = $driver->find_child_elements($external_table, 'tr');
        is(scalar @rows,         2,     'passed results filtered out');
        is($rows[1]->get_text(), $res1, 'softfailure still displayed');
    };
};

subtest 'render video link if frametime is available' => sub {
    $driver->find_element_by_link_text('Details')->click();
    $driver->find_element('[href="#step/bootloader/1"]')->click();
    wait_for_ajax;
    my @links = $driver->find_elements('.step_actions .fa-file-video');
    is($#links, -1, 'no link without frametime');

    $driver->find_element('[href="#step/bootloader/2"]')->click();
    wait_for_ajax;
    my @video_link_elems = $driver->find_elements('.step_actions .fa-file-video');
    is($video_link_elems[0]->get_attribute('title'), 'Jump to video', 'video link exists');
    like($video_link_elems[0]->get_attribute('href'), qr!/tests/99946/file/video.ogv#t=0.00,1.00!,
        'video href correct');
};

subtest 'route to latest' => sub {
    $get
      = $t->get_ok('/tests/latest?distri=opensuse&version=13.1&flavor=DVD&arch=x86_64&test=kde&machine=64bit')
      ->status_is(200);
    my $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->text,   '99963',        'link shows correct test');
    is($header->{href}, '/tests/99963', 'latest link shows tests/99963');
    my $first_detail = $get->tx->res->dom->at('#details tbody > tr ~ tr');
    is($first_detail->at('.component a')->{href}, '/tests/99963/modules/isosize/steps/1/src', 'correct src link');
    is($first_detail->at('.links_a a')->{'data-url'}, '/tests/99963/modules/isosize/steps/1', 'correct needle link');
    $get    = $t->get_ok('/tests/latest?flavor=DVD&arch=x86_64&test=kde')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99963', '... as long as it is unique');
    $get    = $t->get_ok('/tests/latest?version=13.1')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99981', 'returns highest job nr of ambiguous group');
    $get    = $t->get_ok('/tests/latest?test=kde&machine=32bit')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99937', 'also filter on machine');
    my $job_groups_links = $t->tx->res->dom->find('.navbar .dropdown a + ul.dropdown-menu a');
    my ($job_group_text, $build_text) = $job_groups_links->map('text')->each;
    my ($job_group_href, $build_href) = $job_groups_links->map('attr', 'href')->each;
    is($job_group_text, 'opensuse (current)',   'link to current job group overview');
    is($build_text,     ' Build 0091',          'link to test overview');
    is($job_group_href, '/group_overview/1001', 'href to current job group overview');
    like($build_href, qr/distri=opensuse/, 'href to test overview');
    like($build_href, qr/groupid=1001/,    'href to test overview');
    like($build_href, qr/version=13.1/,    'href to test overview');
    like($build_href, qr/build=0091/,      'href to test overview');
    $get = $t->get_ok('/tests/latest?test=foobar')->status_is(404);
};

# test /details route
$driver->get("/tests/99946/details");
$driver->find_element_by_link_text('installer_timezone')->click();
like(
    $driver->get_current_url(),
    qr{.*/tests/99946/modules/installer_timezone/steps/1/src$},
    "on src page from details route"
);

# create 2 additional needle files for this particular test; fixtures are deleted in other tests
my $ntext = <<EOM;
{
  "area": [
    {
      "type": "match",
      "height": 42,
      "ypos": 444,
      "width": 131,
      "xpos": 381
    }
  ],
  "tags": [
      "sudo-passwordprompt",
      "some-other-tag"
  ]
}
EOM
my $needle_dir = 't/data/openqa/share/tests/opensuse/needles';
ok(-d $needle_dir || mkdir($needle_dir), 'create needle directory');
for my $needle_name (qw(sudo-passwordprompt-lxde sudo-passwordprompt)) {
    ok(open(my $fh, '>', "$needle_dir/$needle_name.json"));
    print $fh $ntext;
    close($fh);
}

sub test_with_error {
    my ($needle_to_modify, $error, $tags, $expect, $test_name) = @_;

    # modify the fixture test data: parse JSON -> modify -> write JSON
    if (defined $needle_to_modify || defined $tags) {
        local $/;
        my $fn
          = 't/data/openqa/testresults/00099/00099946-opensuse-13.1-DVD-i586-Build0091-textmode/details-yast2_lan.json';
        ok(open(my $fh, '<', $fn), 'can open JSON file for reading');
        my $details = decode_json(<$fh>);
        close($fh);
        my $detail = $details->[0];
        if (defined $needle_to_modify && defined $error) {
            $detail->{needles}->[$needle_to_modify]->{error} = $error;
        }
        if (defined $tags) {
            $detail->{tags} = $tags;
        }
        ok(open($fh, '>', $fn), 'can open JSON file for writing');
        print $fh encode_json($details);
        close($fh);
    }

    # check whether candidates are displayed as expected
    my $random_number = int(rand(100000));
    $driver->get("/tests/99946?prevent_caching=$random_number#step/yast2_lan/1");
    disable_bootstrap_animations;
    wait_for_ajax;
    is_deeply(find_candidate_needles, $expect, $test_name // 'candidates displayed as expected');
}

subtest 'test candidate list' => sub {
    test_with_error(undef, undef, [], {}, 'no tags at all');

    my %expected_candidates = (
        'this-tag-does-not-exist' => [],
        'sudo-passwordprompt'     => ['63%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'],
    );
    my @tags = sort keys %expected_candidates;
    test_with_error(undef, undef, \@tags, \%expected_candidates, '63%, 52%');
    # notes:
    # - some-other-tag is not in the list because the fixture test isn't looking for it
    # - this-tag-does-not-exist is in the list because the test is looking for it, even though
    #   no needle with the tag actually exists

    $expected_candidates{'sudo-passwordprompt'} = ['68%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'];
    test_with_error(1, 0.1, \@tags, \%expected_candidates, '68%, 52%');
    $expected_candidates{'sudo-passwordprompt'} = ['100%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'];
    test_with_error(1, 0, \@tags, \%expected_candidates, '100%, 52%');

    $expected_candidates{'sudo-passwordprompt'} = ['100%: sudo-passwordprompt', '100%: sudo-passwordprompt-lxde'];
    test_with_error(0, 0, \@tags, \%expected_candidates, '100%, 100%');

    # modify fixture tests to look for some-other-tag as well, needles should now appear twice
    %expected_candidates = (
        'sudo-passwordprompt' => $expected_candidates{'sudo-passwordprompt'},
        'some-other-tag'      => $expected_candidates{'sudo-passwordprompt'},
    );
    test_with_error(0, 0, ['sudo-passwordprompt', 'some-other-tag'],
        \%expected_candidates, 'needles appear twice, each time under different tag');
};

subtest 'filtering' => sub {
    $driver->get('/tests/99937');

    # load Selenium::Remote::WDKeys module or skip this test if not available
    unless (can_load(modules => {'Selenium::Remote::WDKeys' => undef,})) {
        plan skip_all => 'Install Selenium::Remote::WDKeys to run this test';
        return;
    }

    # define test helper
    my $count_steps = sub {
        my ($result) = @_;
        return $driver->execute_script("return \$('#results .result${result}:visible').length;");
    };
    my $count_headings = sub {
        return $driver->execute_script("return \$('#results td[colspan=\"3\"]:visible').length;");
    };

    # check initial state (no filters enabled)
    ok(!$driver->find_element('#details-name-filter')->is_displayed(),        'name filter initially not displayed');
    ok(!$driver->find_element('#details-only-failed-filter')->is_displayed(), 'failed filter initially not displayed');
    is($count_steps->('ok'),     47, 'number of passed steps without filter');
    is($count_steps->('failed'), 3,  'number of failed steps without filter');
    is($count_headings->(),      3,  'number of module headings without filter');

    # show filter form
    $driver->find_element('.details-filter-toggle a')->click();

    # enable name filter
    $driver->find_element('#details-name-filter')->send_keys('at');
    is($count_steps->('ok'),     3, 'number of passed steps only with name filter');
    is($count_steps->('failed'), 1, 'number of failed steps only with name filter');
    is($count_headings->(),      0, 'no module headings shown when filter active');

    # enable failed filter
    $driver->find_element('#details-only-failed-filter')->click();
    is($count_steps->('ok'),     0, 'number of passed steps with both filters');
    is($count_steps->('failed'), 1, 'number of failed steps with both filters');
    is($count_headings->(),      0, 'no module headings shown when filter active');

    # disable name filter
    $driver->find_element('#details-name-filter')->send_keys(
        Selenium::Remote::WDKeys->KEYS->{end},
        Selenium::Remote::WDKeys->KEYS->{backspace},
        Selenium::Remote::WDKeys->KEYS->{backspace},
    );
    is($count_steps->('ok'),     0, 'number of passed steps only with failed filter');
    is($count_steps->('failed'), 3, 'number of failed steps only with failed filter');
    is($count_headings->(),      0, 'no module headings shown when filter active');

    # disable failed filter
    $driver->find_element('#details-only-failed-filter')->click();
    is($count_steps->('ok'),     47, 'same number of passed steps as initial');
    is($count_steps->('failed'), 3,  'same number of failed steps as initial');
    is($count_headings->(),      3,  'module headings shown again');
};

# set job 99963 to done via API to tests whether worker is still displayed then
my $t_api = Test::Mojo->new('OpenQA::WebAPI');
my $app   = $t_api->app;
$t_api->ua(
    OpenQA::Client->new(apikey => '1234567890ABCDEF', apisecret => '1234567890ABCDEF')->ioloop(Mojo::IOLoop->singleton)
);
$t_api->app($app);
my $post
  = $t_api->post_ok($baseurl . 'api/v1/jobs/99963/set_done', form => {result => 'FAILED'})
  ->status_is(200, 'set job as done');

$get         = $t->get_ok($baseurl . 'tests/99963')->status_is(200);
@worker_text = $get->tx->res->dom->find('#assigned-worker')->map('all_text')->each;
like($worker_text[0], qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/, 'worker still displayed when job set to done');
@scenario_description = $get->tx->res->dom->find('#scenario-description')->map('all_text')->each;
like(
    $scenario_description[0],
    qr/[ \n]*Simple kde test, before advanced_kde[ \n]*/,
    'scenario description is displayed'
);

# now test the details of a job with nearly no settings which should yield no
# warnings
$get = $t->get_ok('/tests/80000')->status_is(200);

subtest 'test module flags are displayed correctly' => sub {
    # for this job we have exactly each flag set once, so check that not to rely on the order of the test modules
    $driver->get('/tests/99764');
    my $flags = $driver->find_elements("//div[\@class='flags']/i[(starts-with(\@class, 'flag fa fa-'))]", 'xpath');
    is(scalar(@{$flags}), 4, 'Expect 4 flags in the job 99764');

    my $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-minus']", 'xpath');
    ok($flag, 'Ignore failure flag is displayed for test modules which are not important, neither fatal');
    is(
        $flag->get_attribute('title'),
        'Ignore failure: failure or soft failure of this test does not impact overall job result',
        'Description of Ignore failure flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-redo']", 'xpath');
    ok($flag, 'Always rollback flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Always rollback: revert to the last milestone snapshot even if test module is successful',
        'Description of always_rollback flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-anchor']", 'xpath');
    ok($flag, 'Milestone flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Milestone: snapshot the state after this test for restoring',
        'Description of milestone flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-plug']", 'xpath');
    ok($flag, 'Fatal flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Fatal: testsuite is aborted if this test fails',
        'Description of fatal flag is correct'
    );
};

kill_driver();
done_testing();
