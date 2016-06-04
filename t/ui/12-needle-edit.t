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
#use Test::Output qw/stdout_like stderr_like/;
use OpenQA::Test::Case;

use File::Path qw/make_path remove_tree/;
use POSIX qw/strftime/;
use JSON;

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
unless ($driver) {
    plan skip_all => 'Install phantomjs and Selenium::Remote::Driver to run these tests';
    exit(0);
}

my $elem;
my $baseurl;
my $decode_textarea;
my $dir = "t/data/openqa/share/tests/opensuse/needles";

# clean up needles dir
remove_tree($dir);
make_path($dir);

# default needle JSON content
my $default_json = '{"area" : [{"height" : 217,"type" : "match","width" : 384,"xpos" : 0,"ypos" : 0}],"tags" : ["ENV-VIDEOMODE-text","inst-timezone"]}';

# create a fake json
my $filen = "$dir/inst-timezone-text.json";
{
    local $/;    #Enable 'slurp' mode
    open my $fh, ">", $filen;
    print $fh $default_json;
    close $fh;
}

sub goto_editpage() {
    is($driver->get_title(), "openQA", "on main page");
    $baseurl = $driver->get_current_url();
    $driver->find_element('Login', 'link_text')->click();
    # we're back on the main page
    is($driver->get_title(), "openQA", "back on main page");

    like($driver->find_element('#user-info', 'css')->get_text(), qr/Logged in as Demo.*Logout/, "logged in as demo");

    $driver->get($baseurl . "tests/99946");
    is($driver->get_title(), 'openQA: opensuse-13.1-DVD-i586-Build0091-textmode test results', 'tests/99946 followed');

    $driver->find_element('installer_timezone', 'link_text')->click();
    is($driver->get_current_url(), $baseurl . "tests/99946/modules/installer_timezone/steps/1/src", "on src page for nstaller_timezone test");

    $driver->find_element('Screenshot', 'link_text')->click();

    $driver->find_element('Create new needle', 'link_text')->click();
}

sub editpage_layout_check() {
    t::ui::PhantomTest::wait_for_ajax;

    # layout check
    is($driver->find_element('#tags_select',  'css')->get_value(),   'inst-timezone-text', "inst-timezone tags selected");
    is($driver->find_element('#image_select', 'css')->get_value(),   'screenshot',         "Screenshot background selected");
    is($driver->find_element('#area_select',  'css')->get_value(),   'inst-timezone-text', "inst-timezone areas selected");
    is($driver->find_element('#take_matches', 'css')->is_selected(), 1,                    "Matches selected");

    # check needle suggested name
    my $today = strftime("%Y%m%d", gmtime(time));
    is($driver->find_element('#needleeditor_name', 'css')->get_value(), "inst-timezone-text-$today", "has correct needle name");

    # ENV-VIDEOMODE-text and inst-timezone tag are selected
    is($driver->find_element('//input[@value="inst-timezone"]')->is_selected(), 1, "tag selected");

    # workround property doesn't selected
    is($driver->find_element('#property_workaround', 'css')->is_selected(), 0, "workaround property unselected");

    $elem = $driver->find_element('#needleeditor_textarea', 'css');
    $decode_textarea = decode_json($elem->get_value());
    # the value already defined in $default_json
    is($decode_textarea->{area}[0]->{xpos},   0,   "xpos correct");
    is($decode_textarea->{area}[0]->{ypos},   0,   "ypos correct");
    is($decode_textarea->{area}[0]->{width},  384, "width correct");
    is($decode_textarea->{area}[0]->{height}, 217, "height correct");
}

sub add_needle_tag(;$) {
    my $tagname = shift || 'test-newtag';
    $elem = $driver->find_element('#newtag', 'css');
    $elem->send_keys($tagname);
    $driver->find_element('#tag_add_button', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;
    is($driver->find_element("//input[\@value=\"$tagname\"]")->is_selected(), 1, "new tag found and was checked");
}

sub add_workaround_property() {
    $driver->find_element('#property_workaround', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;
    is($driver->find_element('#property_workaround', 'css')->is_selected(), 1, "workaround property selected");
}

# change_needle_value($xoffset, $yoffset)
sub change_needle_value($$) {
    my $xoffset    = shift;
    my $yoffset    = shift;
    my $pre_offset = 10;      # we need this value as first position the cursor moved on
    my $decode_new_textarea;

    $elem = $driver->find_element('#needleeditor_textarea', 'css');
    $decode_textarea = decode_json($elem->get_value());

    $elem = $driver->find_element('#needleeditor_canvas', 'css');
    $driver->mouse_move_to_location(element => $elem, xoffset => $decode_textarea->{area}[0]->{xpos} + $pre_offset, yoffset => $decode_textarea->{area}[0]->{ypos} + $pre_offset);
    $driver->button_down();
    $driver->mouse_move_to_location(element => $elem, xoffset => $decode_textarea->{area}[0]->{xpos} + $xoffset + $pre_offset, yoffset => $decode_textarea->{area}[0]->{ypos} + $yoffset + $pre_offset);
    $driver->button_up();
    t::ui::PhantomTest::wait_for_ajax;
    $elem = $driver->find_element('#needleeditor_textarea', 'css');
    # check the value of textarea again
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{xpos}, $xoffset, "new xpos correct");
    is($decode_new_textarea->{area}[0]->{ypos}, $yoffset, "new ypos correct");

    # test match type
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{type}, "match", "type is match");
    $driver->double_click;    # the match type change to exclude
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{type}, "exclude", "type is exclude");
    $driver->double_click;    # the match type change to ocr
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{type}, "ocr", "type is ocr");
    $driver->double_click;    # the match type change back to match

    unlike($driver->find_element('#change-match', 'css')->get_attribute('class'), qr/disabled/, "match level now enabled");

    # test match level
    $driver->find_element('#change-match', 'css')->click();
    # wait for the fade
    sleep 1;
    t::ui::PhantomTest::wait_for_ajax;

    my $dialog = $driver->find_element('#change-match-form', 'css');

    #t::ui::PhantomTest::make_screenshot('mojoResults.png');
    #print $driver->get_page_source();

    is($driver->find_element('#set_match', 'css')->is_displayed(), 1, "found set button");
    is($driver->find_element('//input[@id="match"]')->get_value(), "96", "default match level is 96");
    $driver->find_element('//input[@id="match"]')->clear();
    $driver->find_element('//input[@id="match"]')->send_keys("99");
    is($driver->find_element('//input[@id="match"]')->get_value(), "99", "set match level to 99");
    $driver->find_element('#set_match', 'css')->click();
    is($driver->find_element('#change-match-form', 'css')->is_hidden(), 1, "match level form closed");
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{match}, 99, "match level is 99 now");
}

# overwrite_needle($needlename);
sub overwrite_needle($) {
    my $needlename = shift;
    $driver->find_element('#needleeditor_name', 'css')->clear();
    is($driver->find_element('#needleeditor_name', 'css')->get_value(), "", "needle name input clean up");
    $driver->find_element('#needleeditor_name', 'css')->send_keys($needlename);
    is($driver->find_element('#needleeditor_name', 'css')->get_value(), "$needlename", "new needle name inputed");
    $driver->find_element('#save', 'css')->click();
    t::ui::PhantomTest::wait_for_ajax;
    # check the state highlight changed and click Yes do overwrite then
    is($driver->find_element('ui-state-highlight', 'class')->get_text(), "Same needle name file already exists! Overwrite it? Yes / No", "highlight appears correct");
    $driver->find_element('Yes', 'link_text')->click();
    t::ui::PhantomTest::wait_for_ajax;
    is($driver->find_element('ui-state-highlight', 'class')->get_text(), "Needle test-newneedle created/updated.", "highlight appears correct");
    ok(-f "$dir/$needlename.json", "$needlename.json overwrited");
}

# start testing
goto_editpage();
editpage_layout_check();

# creating new needle
add_needle_tag();

my $needlename = 'test-newneedle';

# check needle name input
$driver->find_element('#needleeditor_name', 'css')->clear();
is($driver->find_element('#needleeditor_name', 'css')->get_value(), "", "needle name input clean up");
$driver->find_element('#needleeditor_name', 'css')->send_keys($needlename);
is($driver->find_element('#needleeditor_name', 'css')->get_value(), "$needlename", "new needle name inputed");

# create new needle by clicked save button
$driver->find_element('#save', 'css')->click();
t::ui::PhantomTest::wait_for_ajax;
# check state highlight appears with valid content
is($driver->find_element('ui-state-highlight', 'class')->get_text(), "Needle test-newneedle created/updated.", "highlight appears correct");
# check files are exists
ok(-f "$dir/$needlename.json", "$needlename.json created");
ok(-f "$dir/$needlename.png",  "$needlename.png created");

# test overwrite needle
add_needle_tag('test-overwritetag');
add_workaround_property();

like($driver->find_element('#change-match', 'css')->get_attribute('class'), qr/disabled/, "match level disabled");

# change area
my $xoffset = my $yoffset = 200;
change_needle_value($xoffset, $yoffset);    # xoffset and yoffset 200 for new area
overwrite_needle($needlename);

# parse new needle json
my $new_needle_path = "$dir/$needlename.json";
my $overwrite_json;
{
    local $/;                               #Enable 'slurp' mode
    open my $fh, "<", $new_needle_path;
    $overwrite_json = <$fh>;
    close $fh;
}
my $decode_json = decode_json($overwrite_json);
my $new_tags    = $decode_json->{'tags'};

# check new needle json is correct
my $match = 0;
for my $tag (@$new_tags) {
    $match = 1 if ($tag eq 'test-overwritetag');
}
is($match,                            1,                                                "found new tag in new needle");
is($decode_json->{'area'}[0]->{xpos}, $decode_textarea->{'area'}[0]->{xpos} + $xoffset, "new xpos stored to new needle");
is($decode_json->{'area'}[0]->{ypos}, $decode_textarea->{'area'}[0]->{ypos} + $yoffset, "new ypos stored to new needle");

t::ui::PhantomTest::kill_phantom();

subtest '(created) needles can be accessed over API' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->get_ok('/needles/opensuse/test-newneedle.png')->status_is(200)->content_type_is('image/png');
    my @warnings = warnings { $t->get_ok('/needles/opensuse/doesntexist.png')->status_is(404) };
    map { like($_, qr/No such file or directory/, 'expected warning') } @warnings;

    $t->get_ok('/needles/opensuse/test-newneedle.png?jsonfile=t/data/openqa/share/tests/opensuse/needles/test-newneedle.json')->status_is(200)->content_type_is('image/png');
    @warnings = warnings { $t->get_ok('/needles/opensuse/test-newneedle.png?jsonfile=/try/to/break_out.json')->status_is(403) };
    map { like($_, qr/is not in a subdir of/, 'expected warning') } @warnings;
};

done_testing();
