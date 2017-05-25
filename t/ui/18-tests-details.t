#! /usr/bin/perl

# Copyright (C) 2014-2017 SUSE LLC
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
use JSON;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

sub schema_hook {
    my $schema = OpenQA::Test::Database->new->create;
    my $jobs   = $schema->resultset('Jobs');

    # set assigned_worker_id to test whether worker still displayed when job set to done
    # manually for PhantomJS test
    $jobs->find(99963)->update({assigned_worker_id => 1});
}

my $driver = call_phantom(\&schema_hook);
unless ($driver) {
    plan skip_all => $t::ui::PhantomTest::phantommissing;
    exit(0);
}
my $baseurl = $driver->get_current_url;

sub disable_bootstrap_fade_animation {
    $driver->execute_script(
"document.styleSheets[0].addRule('.fade', '-webkit-transition: none !important; transition: none !important;', 1);"
    );
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
disable_bootstrap_fade_animation;
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
my $elem = $driver->find_element('.step_actions .fa-info-circle');
like($elem->get_attribute('data-content'), qr/inst-bootmenu/, "show searched needle tags");
$elem->click();
wait_for_ajax;
ok($driver->find_element('.step_actions .popover')->is_displayed(), "needle info is a clickable popover");
$driver->find_element_by_xpath('//a[@href="#step/installer_timezone/1"]')->click();
wait_for_ajax;

my @report_links = $driver->find_elements('#preview_container_in .report', 'css');
my @title = map { $_->get_attribute('title') } @report_links;
is($title[0], 'Report product bug', 'product bug report URL available');
is($title[1], 'Report test issue',  'test issue report URL available');
my @url = map { $_->get_attribute('href') } @report_links;
like($url[0], qr{bugzilla.*enter_bug.*tests%2F99937}, 'bugzilla link referencing current test');
like($url[1], qr{progress.*new}, 'progress/redmine link for reporting test issues');

# test running view with Test::Mojo as phantomjs would get stuck on the
# liveview/livelog forever
my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $get = $t->get_ok($baseurl . 'tests/99963')->status_is(200);

my @worker_text = $get->tx->res->dom->find('#info_box .panel-body div + div + div')->map('all_text')->each;
like($worker_text[0], qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/, 'worker displayed when job running');
my @worker_href = $get->tx->res->dom->find('#info_box .panel-body div + div + div a')->map(attr => 'href')->each;
is($worker_href[0], '/admin/workers/1', 'link to worker correct');

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
    my @a = $driver->find_elements('#preview_container_in a', 'css');
    is((shift @a)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bugref href correct');
    is((shift @a)->get_attribute('href'), 'https://fate.suse.com/321208', 'regular href correct');
};

subtest 'render video link if frametime is available' => sub {
    $driver->get('/tests/99946');
    $driver->find_element('[href="#step/bootloader/1"]')->click();
    wait_for_ajax;
    is(1, 1, 'dummy');
    my @links = $driver->find_elements('.step_actions .fa-file-video-o');
    is($#links, -1, 'no link without frametime');

    $driver->find_element('[href="#step/bootloader/2"]')->click();
    wait_for_ajax;
    my @video_link_elems = $driver->find_elements('.step_actions .fa-file-video-o');
    is($video_link_elems[0]->get_attribute('title'), 'Jump to video', 'video link exists');
    like($video_link_elems[0]->get_attribute('href'), qr!/tests/99946/file/video.ogv#t=0.00,1.00!,
        'video href correct');
};

subtest 'route to latest' => sub {
    $get
      = $t->get_ok('/tests/latest?distri=opensuse&version=13.1&flavor=DVD&arch=x86_64&test=kde&machine=64bit')
      ->status_is(200);
    my $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->text,   '99963',        'link shows correct test');
    is($header->{href}, '/tests/99963', 'latest link shows tests/99963');
    my $first_detail = $get->tx->res->dom->at('#details tbody > tr ~ tr');
    is($first_detail->at('.component a')->{href}, '/tests/99963/modules/isosize/steps/1/src', 'correct src link');
    is($first_detail->at('.links_a a')->{'data-url'}, '/tests/99963/modules/isosize/steps/1', 'correct needle link');
    $get    = $t->get_ok('/tests/latest?flavor=DVD&arch=x86_64&test=kde')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->{href}, '/tests/99963', '... as long as it is unique');
    $get    = $t->get_ok('/tests/latest?version=13.1')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->{href}, '/tests/99981', 'returns highest job nr of ambiguous group');
    $get    = $t->get_ok('/tests/latest?test=kde&machine=32bit')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->{href}, '/tests/99937', 'also filter on machine');
    my $job_groups_links = $t->tx->res->dom->find('.nav .dropdown a + ul.dropdown-menu li a');
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

# create 2 needle files, so they are there. The fixtures are deleted in other tests
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
    "sudo-password"
  ]
}
EOM

open(my $fh, '>', 't/data/openqa/share/tests/opensuse/needles/sudo-passwordprompt-lxde.json');
print $fh $ntext;
close($fh);
open($fh, '>', 't/data/openqa/share/tests/opensuse/needles/sudo-passwordprompt.json');
print $fh $ntext;
close($fh);

sub test_with_error {
    my ($needle, $error, $expect) = @_;

    if (defined $needle) {
        local $/;
        my $fn
          = 't/data/openqa/testresults/00099/00099946-opensuse-13.1-DVD-i586-Build0091-textmode/details-yast2_lan.json';
        open(my $fh, '<', $fn);
        my $details = decode_json(<$fh>);
        close($fh);
        $details->[0]->{needles}->[$needle]->{error} = $error;
        open($fh, '>', $fn);
        print $fh encode_json($details);
        close($fh);
    }

    $driver->get("/tests/99946#step/yast2_lan/1");
    wait_for_ajax;

    my $text = $driver->find_element_by_id('needlediff_selector')->get_text();
    $text =~ s,\s+, ,g;
    is($text, $expect, "combo box matches");
}

# default fixture
test_with_error(undef, undef, " -None- 63%: sudo-passwordprompt-lxde 52%: sudo-passwordprompt ");
test_with_error(1,     0.1,   " -None- 68%: sudo-passwordprompt-lxde 52%: sudo-passwordprompt ");
test_with_error(1,     0,     " -None- 100%: sudo-passwordprompt-lxde 52%: sudo-passwordprompt ");
# when the error is the same, the one without suffix is first
test_with_error(0, 0, " -None- 100%: sudo-passwordprompt 100%: sudo-passwordprompt-lxde ");

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
@worker_text = $get->tx->res->dom->find('#info_box .panel-body div + div + div')->map('all_text')->each;
like($worker_text[0], qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/, 'worker still displayed when job set to done');

kill_phantom();
done_testing();
