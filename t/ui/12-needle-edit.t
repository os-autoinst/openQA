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
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use OpenQA::Test::Case;
use Cwd qw(abs_path);

use File::Path qw(make_path remove_tree);
use POSIX qw(strftime);
use JSON;

use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ws = OpenQA::WebSockets->new;
my $sh = OpenQA::Scheduler->new;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = call_phantom();
unless ($driver) {
    plan skip_all => $t::ui::PhantomTest::phantommissing;
    exit(0);
}

my $elem;
my $decode_textarea;
my $dir = 't/data/openqa/share/tests/opensuse/needles';

# clean up needles dir
remove_tree($dir);
make_path($dir);

# default needle JSON content
my $default_json
  = '{"area" : [{"height" : 217,"type" : "match","width" : 384,"xpos" : 0,"ypos" : 0}],"tags" : ["ENV-VIDEOMODE-text","inst-timezone"]}';

# create a fake json
my $filen = "$dir/inst-timezone-text.json";
{
    local $/;    #Enable 'slurp' mode
    open my $fh, ">", $filen;
    print $fh $default_json;
    close $fh;
}

sub open_needle_editor {
    # init the preview
    wait_for_ajax;

    $driver->find_element_by_xpath('//a[@href="#step/installer_timezone/1"]')->click();

    # init the diff
    wait_for_ajax;

    $driver->find_element('.step_actions .create_new_needle')->click();
}

sub goto_editpage() {
    $driver->title_is("openQA", "on main page");
    $driver->find_element_by_link_text('Login')->click();
    # we're back on the main page
    $driver->title_is("openQA", "back on main page");

    is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

    $driver->get("/tests/99946");
    is(
        $driver->get_title(),
        'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results',
        'tests/99946 followed'
    );

    open_needle_editor;

    # no warnings about missing/bad needles present (yet)
    my @warnings = $driver->find_elements('#editor_warnings', 'css');
    is(scalar @warnings, 0, 'no warnings');
}

sub editpage_layout_check() {
    wait_for_ajax;

    # layout check
    is($driver->find_element_by_id('tags_select')->get_value(), 'inst-timezone-text', "inst-timezone tags selected");
    is($driver->find_element_by_id('image_select')->get_value(), 'screenshot', "Screenshot background selected");
    is($driver->find_element_by_id('area_select')->get_value(), 'inst-timezone-text', "inst-timezone areas selected");
    is($driver->find_element_by_id('take_matches')->is_selected(), 1, "Matches selected");

    # check needle suggested name
    my $today = strftime("%Y%m%d", gmtime(time));
    is($driver->find_element_by_id('needleeditor_name')->get_value(),
        "inst-timezone-text-$today", "has correct needle name");

    # ENV-VIDEOMODE-text and inst-timezone tag are selected
    is($driver->find_element_by_xpath('//input[@value="inst-timezone"]')->is_selected(), 1, "tag selected");

    # workround property doesn't selected
    is($driver->find_element_by_id('property_workaround')->is_selected(), 0, "workaround property unselected");

    $elem            = $driver->find_element_by_id('needleeditor_textarea');
    $decode_textarea = decode_json($elem->get_value());
    # the value already defined in $default_json
    is($decode_textarea->{area}[0]->{xpos},   0,   "xpos correct");
    is($decode_textarea->{area}[0]->{ypos},   0,   "ypos correct");
    is($decode_textarea->{area}[0]->{width},  384, "width correct");
    is($decode_textarea->{area}[0]->{height}, 217, "height correct");
}

sub add_needle_tag(;$) {
    my $tagname = shift || 'test-newtag';
    $elem = $driver->find_element_by_id('newtag');
    $elem->send_keys($tagname);
    $driver->find_element_by_id('tag_add_button')->click();
    wait_for_ajax;
    is($driver->find_element_by_xpath("//input[\@value=\"$tagname\"]")->is_selected(),
        1, "new tag found and was checked");
}

sub add_workaround_property() {
    $driver->find_element_by_id('property_workaround')->click();
    wait_for_ajax;
    is($driver->find_element_by_id('property_workaround')->is_selected(), 1, "workaround property selected");
}

sub create_needle {
    my ($xoffset, $yoffset) = @_;

    my $pre_offset = 10;    # we need this value as first position the cursor moved on
    my $elem = $driver->find_element_by_id('needleeditor_canvas');
    $driver->mouse_move_to_location(
        element => $elem,
        xoffset => $decode_textarea->{area}[0]->{xpos} + $pre_offset,
        yoffset => $decode_textarea->{area}[0]->{ypos} + $pre_offset
    );
    $driver->button_down();
    $driver->mouse_move_to_location(
        element => $elem,
        xoffset => $decode_textarea->{area}[0]->{xpos} + $xoffset + $pre_offset,
        yoffset => $decode_textarea->{area}[0]->{ypos} + $yoffset + $pre_offset
    );
    $driver->button_up();
    wait_for_ajax;
}

sub change_needle_value($$) {
    my ($xoffset, $yoffset) = @_;

    decode_json($driver->find_element_by_id('needleeditor_textarea')->get_value());
    create_needle($xoffset, $yoffset);

    # check the value of textarea again
    my $elem                = $driver->find_element_by_id('needleeditor_textarea');
    my $decode_new_textarea = decode_json($elem->get_value());
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

    unlike($driver->find_element_by_id('change-match')->get_attribute('class'),
        qr/disabled/, "match level now enabled");

    # test match level
    $driver->find_element_by_id('change-match')->click();
    wait_for_ajax;

    my $dialog = $driver->find_element_by_id('change-match-form');

    is($driver->find_element_by_id('set_match')->is_displayed(),            1,    "found set button");
    is($driver->find_element_by_xpath('//input[@id="match"]')->get_value(), "96", "default match level is 96");
    $driver->find_element_by_xpath('//input[@id="match"]')->clear();
    $driver->find_element_by_xpath('//input[@id="match"]')->send_keys("99");
    is($driver->find_element_by_xpath('//input[@id="match"]')->get_value(), "99", "set match level to 99");
    $driver->find_element_by_id('set_match')->click();
    is($driver->find_element_by_id('change-match-form')->is_hidden(), 1, "match level form closed");
    $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{match}, 99, "match level is 99 now");
}

sub overwrite_needle($) {
    my ($needlename) = @_;

    # remove animation from modal to speed up test
    $driver->execute_script('$(\'#modal-overwrite\').removeClass(\'fade\');');

    $driver->find_element_by_id('needleeditor_name')->clear();
    is($driver->find_element_by_id('needleeditor_name')->get_value(), "", "needle name input clean up");
    $driver->find_element_by_id('needleeditor_name')->send_keys($needlename);
    is($driver->find_element_by_id('needleeditor_name')->get_value(), "$needlename", "new needle name inputed");
    $driver->find_element_by_id('save')->click();
    wait_for_ajax;
    my $diag;
    $diag = $driver->find_element_by_id('modal-overwrite');
    is($driver->find_child_element($diag, '.modal-title', 'css')->is_displayed(), 1, "We can see the overwrite dialog");
    is(
        $driver->find_child_element($diag, '.modal-title', 'css')->get_text(),
        "Sure to overwrite test-newneedle?",
        "Needle part of the title"
    );

    $driver->find_element_by_id('modal-overwrite-confirm')->click();

    wait_for_ajax;
    is(
        $driver->find_element('#flash-messages span')->get_text(),
        'Needle test-newneedle created/updated - restart job',
        'highlight appears correct'
    );
    ok(-f "$dir/$needlename.json", "$needlename.json overwritten");

    $driver->find_element('#flash-messages span a')->click();
    # restart is an ajax call, for some reason the check/sleep interval must be at least 1 sec for this call
    wait_for_ajax(1);
    is(
        $driver->get_title(),
        'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results',
        "no longer on needle editor"
    );
}

# start testing
goto_editpage();
editpage_layout_check();

# creating new needle
add_needle_tag();

my $needlename = 'test-newneedle';

# check needle name input
$driver->find_element_by_id('needleeditor_name')->clear();
is($driver->find_element_by_id('needleeditor_name')->get_value(), "", "needle name input clean up");
$driver->find_element_by_id('needleeditor_name')->send_keys($needlename);
is($driver->find_element_by_id('needleeditor_name')->get_value(), "$needlename", "new needle name inputed");

# create new needle by clicked save button
$driver->find_element_by_id('save')->click();
wait_for_ajax;

# check state highlight appears with valid content
is(
    $driver->find_element('#flash-messages span')->get_text(),
    'Needle test-newneedle created/updated - restart job',
    'highlight appears correct'
);
# check files are exists
ok(-f "$dir/$needlename.json", "$needlename.json created");
ok(-f "$dir/$needlename.png",  "$needlename.png created");

# test overwrite needle
add_needle_tag('test-overwritetag');
add_workaround_property();

like($driver->find_element_by_id('change-match')->get_attribute('class'), qr/disabled/, "match level disabled");

# change area
my $xoffset = my $yoffset = 200;
change_needle_value($xoffset, $yoffset);    # xoffset and yoffset 200 for new area
overwrite_needle($needlename);

subtest 'Saving needle without taking matches' => sub {
    $driver->get('/tests/99938/modules/logpackages/steps/1/edit');
    $driver->find_element_by_id('tag_ENV-DESKTOP-kde')->click();
    $driver->find_element_by_id('take_matches')->click();
    create_needle(20, 50);
    $driver->find_element_by_id('save')->click();
    like(
        $driver->find_element('#flash-messages span')->get_text(),
        qr/Needle logpackages-before-package-selection-\d{8} created\/updated - restart job/,
        'highlight appears correct'
    );
};

# parse new needle json
my $new_needle_path = "$dir/$needlename.json";
my $overwrite_json;
{
    local $/;    #Enable 'slurp' mode
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
is($match, 1, "found new tag in new needle");
is($decode_json->{'area'}[0]->{xpos}, $decode_textarea->{'area'}[0]->{xpos} + $xoffset,
    "new xpos stored to new needle");
is($decode_json->{'area'}[0]->{ypos}, $decode_textarea->{'area'}[0]->{ypos} + $yoffset,
    "new ypos stored to new needle");

subtest 'Deletion of needle is handled gracefully' => sub {
    # re-open the needle editor after deleting needle
    unlink $filen;
    $driver->get("/tests/99946");
    is(
        $driver->get_title(),
        'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results',
        'tests/99946 followed'
    );
    open_needle_editor;
    $driver->title_is('openQA: Needle Editor', 'needle editor still shows up');
    is(
        $driver->find_element('#editor_warnings span')->get_text(),
        'Could not find needle: inst-timezone-text for opensuse 13.1',
        'warning about deleted needle is displayed'
    );
};

subtest 'areas/tags verified via JavaScript' => sub {
    $driver->get('/tests/99938/modules/logpackages/steps/1/edit');
    $driver->find_element_by_id('save')->click();
    is(
        $driver->find_element('.alert-danger span')->get_text(),
        "Unable to save needle:\nNo tags specified.\nNo areas defined.",
        'areas/tags verified via JavaScript'
    );
    $driver->find_element('.alert-danger button')->click();
};

kill_phantom();

subtest '(created) needles can be accessed over API' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->get_ok('/needles/opensuse/test-newneedle.png')->status_is(200)->content_type_is('image/png');
    my @warnings = warnings { $t->get_ok('/needles/opensuse/doesntexist.png')->status_is(404) };
    map { like($_, qr/No such file or directory/, 'expected warning') } @warnings;

    $t->get_ok(
        '/needles/opensuse/test-newneedle.png?jsonfile=t/data/openqa/share/tests/opensuse/needles/test-newneedle.json')
      ->status_is(200, 'needle accessible')->content_type_is('image/png');
    @warnings = warnings {
        $t->get_ok('/needles/opensuse/test-newneedle.png?jsonfile=/try/to/break_out.json')
          ->status_is(403, 'access to files outside the test directory not granted')
    };
    map { like($_, qr/is not in a subdir of/, 'expected warning') } @warnings;

    my $tmp_dir = 't/tmp_needles';
    File::Path::rmtree($tmp_dir);
    File::Copy::move($dir, $tmp_dir) || die 'failed to move';
    symlink(abs_path($tmp_dir), $dir);
    $t->get_ok(
        '/needles/opensuse/test-newneedle.png?jsonfile=t/data/openqa/share/tests/opensuse/needles/test-newneedle.json')
      ->status_is(200, 'needle also accessible when containing directory is a symlink')->content_type_is('image/png');
    unlink($dir);
    File::Copy::move($tmp_dir, $dir);
};

done_testing();
