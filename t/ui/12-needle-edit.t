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
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

use File::Path qw/make_path remove_tree/;
use POSIX qw/strftime/;
use JSON;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use t::ui::PhantomTest;

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 48;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
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
    local $/; #Enable 'slurp' mode
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

    like($driver->find_element('#user-info', 'css')->get_text(), qr/Logged as Demo.*Logout/, "logged in as demo");

    $driver->find_element('div.big-button a', 'css')->click();
    is($driver->get_current_url(), $baseurl . "tests/", "on /tests");
    is($driver->get_title(), "openQA: Test results", "on tests page");

    # Test 99946 is successful (29/0/1)
    my $job99946 = $driver->find_element('#results #job_99946', 'css');
    my @tds = $driver->find_child_elements($job99946, "td");
    is((shift @tds)->get_text(), 'Build0091 of opensuse-13.1-DVD.i586', "medium of 99946");
    is((shift @tds)->get_text(), 'textmode@32bit', "test of 99946");
    is((shift @tds)->get_text(), '29 1', "result of 99946");
    is((shift @tds)->get_text(), "", "no deps of 99946");
    like((shift @tds)->get_text(), qr/a minute ago/, "time of 99946");

    $driver->find_element('#results #job_99946 td.test a', 'css')->click();
    is($driver->get_title(), 'openQA: opensuse-13.1-DVD-i586-Build0091-textmode test results', 'tests/99946 followed');

    $driver->find_element('installer_timezone', 'link_text')->click();
    is($driver->get_current_url(), $baseurl . "tests/99946/modules/installer_timezone/steps/1/src", "on src page for nstaller_timezone test");

    $driver->find_element('Needles editor', 'link_text')->click();
}

sub editpage_layout_check() {
    # layout check
    $elem = $driver->find_element('#screens_table tbody tr', 'css');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(5, @headers, "5 columns");
    is((shift @headers)->get_text(), "Screens./Needle",    "1st column");
    is((shift @headers)->get_text(), "Image", "2nd column");
    is((shift @headers)->get_text(), "Areas",  "3rd column");
    is((shift @headers)->get_text(), "Matches", "4th column");
    is((shift @headers)->get_text(), "Tags", "5th column");
    is($driver->find_element('#bg_btn_screenshot', 'css')->is_selected(), 1, "background selected");
    is($driver->find_element('#bg_btn_inst-timezone-text', 'css')->is_selected(), 0, "background unselected");
    is($driver->find_element('#tags_btn_screenshot', 'css')->is_selected(), 0, "tag btn unselected");
    is($driver->find_element('#tags_btn_inst-timezone-text', 'css')->is_selected(), 1, "tag btn selected");
    is($driver->find_element('#matches_btn_inst-timezone-text', 'css')->is_selected(), 1, "matches btn selected");

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
    is($decode_textarea->{area}[0]->{xpos}, 0, "xpos correct");
    is($decode_textarea->{area}[0]->{ypos}, 0, "ypos correct");
    is($decode_textarea->{area}[0]->{width}, 384, "width correct");
    is($decode_textarea->{area}[0]->{height}, 217, "height correct");
}

sub add_needle_tag(;$) {
    my $tagname = shift || 'test-newtag';
    $elem = $driver->find_element('#newtag', 'css');
    $elem->send_keys($tagname);
    $driver->find_element('#tag_add_button', 'css')->click();
    # leave the ajax some time
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is(1, $driver->find_element("//input[\@value=\"$tagname\"]")->is_selected(), "new tag found and was checked");
}

sub add_workaround_property() {
    $driver->find_element('#property_workaround', 'css')->click();
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    is($driver->find_element('#property_workaround', 'css')->is_selected(), 1, "workaround property selected");
}

# change_needle_area($offset)
sub change_needle_area($$) {
    my $xoffset = shift;
    my $yoffset = shift;
    my $pre_offset = 10; # we need this value as first position the cursor moved on

    $elem = $driver->find_element('#needleeditor_textarea', 'css');
    $decode_textarea = decode_json($elem->get_value());

    $elem = $driver->find_element('#needleeditor_canvas', 'css');
    $driver->mouse_move_to_location(element => $elem, xoffset => $decode_textarea->{area}[0]->{xpos} + $pre_offset, yoffset => $decode_textarea->{area}[0]->{ypos} + $pre_offset);
    $driver->button_down();
    $driver->mouse_move_to_location(element => $elem, xoffset => $decode_textarea->{area}[0]->{xpos} + $xoffset + $pre_offset, yoffset => $decode_textarea->{area}[0]->{ypos} + $yoffset + $pre_offset);
    $driver->button_up();
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }

    # check the value of textarea again
    $elem = $driver->find_element('#needleeditor_textarea', 'css');
    my $decode_new_textarea = decode_json($elem->get_value());
    is($decode_new_textarea->{area}[0]->{xpos}, $xoffset, "new xpos correct");
    is($decode_new_textarea->{area}[0]->{ypos}, $yoffset, "new ypos correct");
}

# overwrite_needle($needlename);
sub overwrite_needle($) {
    my $needlename = shift;
    $driver->find_element('#needleeditor_name', 'css')->clear();
    is($driver->find_element('#needleeditor_name', 'css')->get_value(), "", "needle name input clean up");
    $driver->find_element('#needleeditor_name', 'css')->send_keys($needlename);
    is($driver->find_element('#needleeditor_name', 'css')->get_value(), "$needlename", "new needle name inputed");
    $driver->find_element('//input[@alt="Save"]')->click();
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
    # check the state highlight changed and click Yes do overwrite then
    is($driver->find_element('ui-state-highlight', 'class')->get_text(), "Same needle name file already exists! Overwrite it? Yes / No", "highlight appears correct");
    $driver->find_element('Yes', 'link_text')->click();
    while (!$driver->execute_script("return jQuery.active == 0")) {
        sleep 1;
    }
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
$driver->find_element('//input[@alt="Save"]')->click();
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
# check state highlight appears with valid content
is($driver->find_element('ui-state-highlight', 'class')->get_text(), "Needle test-newneedle created/updated.", "highlight appears correct");
# check files are exists
ok(-f "$dir/$needlename.json", "$needlename.json created");
ok(-f "$dir/$needlename.png", "$needlename.png created");

# test overwrite needle
add_needle_tag('test-overwritetag');
add_workaround_property();
# change area
my $xoffset = my $yoffset = 200;
change_needle_area($xoffset, $yoffset); # xoffset and yoffset 200
overwrite_needle($needlename);

# parse new needle json
my $new_needle_path = "$dir/$needlename.json";
my $overwrite_json;
{
    local $/; #Enable 'slurp' mode
    open my $fh, "<", $new_needle_path;
    $overwrite_json = <$fh>;
    close $fh;
}
my $decode_json = decode_json($overwrite_json);
my $new_tags = $decode_json->{'tags'};

# check new needle json is correct
my $match = 0;
for my $tag (@$new_tags) {
    $match = 1 if ($tag eq 'test-overwritetag');
}
is($match, 1, "found new tag in new needle");
is($decode_json->{'area'}[0]->{xpos}, $decode_textarea->{'area'}[0]->{xpos} + $xoffset, "new xpos stored to new needle");
is($decode_json->{'area'}[0]->{ypos}, $decode_textarea->{'area'}[0]->{ypos} + $yoffset, "new ypos stored to new needle");

t::ui::PhantomTest::kill_phantom();
done_testing();
