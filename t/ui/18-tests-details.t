# Copyright (C) 2014-2016 SUSE LLC
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
use Test::Warnings ':all';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");

is($driver->find_element('#user-action', 'css')->get_text(), 'Logged in as Demo', "logged in as demo");

$driver->get($baseurl . "tests/99946");
is($driver->get_title(), 'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results', 'tests/99946 followed');

$driver->find_element('installer_timezone', 'link_text')->click();
is($driver->get_current_url(), $baseurl . "tests/99946/modules/installer_timezone/steps/1/src", "on src page for nstaller_timezone test");

is($driver->find_element('.cm-comment', 'css')->get_text(), '#!/usr/bin/perl -w', "we have a perl comment");

$driver->get($baseurl . "tests/99937");
sub current_tab {
    return $driver->find_element('.nav.nav-tabs .active', 'css')->get_text;
}
is(current_tab, 'Details', 'starting on Details tab for completed job');
$driver->find_element('Settings', 'link_text')->click();
is(current_tab, 'Settings', 'switched to settings tab');
$driver->go_back();
is(current_tab, 'Details', 'back to details tab');

$driver->find_element('[title="wait_serial"]', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;
ok($driver->find_element('#preview_container_out', 'css')->is_displayed(), "preview window opens on click");
like($driver->find_element('#preview_container_in', 'css')->get_text(), qr/wait_serial expected/, "Preview text with wait_serial output shown");
like($driver->get_current_url(), qr/#step/, "current url contains #step hash");
$driver->find_element('[title="wait_serial"]', 'css')->click();
ok($driver->find_element('#preview_container_out', 'css')->is_hidden(), "preview window closed after clicking again");
unlike($driver->get_current_url(), qr/#step/, "current url doesn't contain #step hash anymore");

# test running view with Test::Mojo as phantomjs would get stuck on the
# liveview/livelog forever
my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $get = $t->get_ok($baseurl . 'tests/99963')->status_is(200);

# test that only one tab is active when using step url
my $num_active_tabs = $t->tx->res->dom->find('.tab-pane.active')->size;
is($num_active_tabs, 1, 'only one tab visible at the same time');

my $href_to_isosize = $t->tx->res->dom->at('.component a[href*=installer_timezone]')->{href};
$t->get_ok($baseurl . ($href_to_isosize =~ s@^/@@r))->status_is(200);

subtest 'route to latest' => sub {
    $get = $t->get_ok($baseurl . 'tests/latest?distri=opensuse&version=13.1&flavor=DVD&arch=x86_64&test=kde&machine=64bit')->status_is(200);
    my $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->text,   '99963',        'link shows correct test');
    is($header->{href}, '/tests/99963', 'latest link shows tests/99963');
    my $first_detail = $get->tx->res->dom->at('#details tbody > tr ~ tr');
    is($first_detail->at('.component a')->{href},     '/tests/99963/modules/isosize/steps/1/src', 'correct src link');
    is($first_detail->at('.links_a a')->{'data-url'}, '/tests/99963/modules/isosize/steps/1',     'correct needle link');
    $get    = $t->get_ok($baseurl . 'tests/latest?flavor=DVD&arch=x86_64&test=kde')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->{href}, '/tests/99963', '... as long as it is unique');
    $get    = $t->get_ok($baseurl . 'tests/latest?version=13.1')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .panel-heading a');
    is($header->{href}, '/tests/99981', 'returns highest job nr of ambiguous group');
    $get = $t->get_ok($baseurl . 'tests/latest?test=foobar')->status_is(404);
};

#print $driver->get_page_source();
#t::ui::PhantomTest::make_screenshot('mojoResults.png');

t::ui::PhantomTest::kill_phantom();
done_testing();
