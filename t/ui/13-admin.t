#! /usr/bin/perl

# Copyright (C) 2015-2019 SUSE LLC
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
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(remove_tree);
use File::Spec::Functions 'catfile';
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use Date::Format 'time2str';
use IO::Socket::INET;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional qw(can_load);

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

use OpenQA::SeleniumTest;

sub schema_hook {
    my $schema     = OpenQA::Test::Database->new->create;
    my $job_groups = $schema->resultset('JobGroups');
    my $assets     = $schema->resultset('Assets');

    $assets->find(2)->update(
        {
            size            => 4096,
            last_use_job_id => 99962,
            t_created       => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
        });

    $job_groups->find(1002)->update(
        {
            exclusively_kept_asset_size => 4096,
        });
}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# DO NOT MOVE THIS INTO A 'use' FUNCTION CALL! It will cause the tests
# to crash if the module is unavailable
unless (can_load(modules => {'Selenium::Remote::WDKeys' => undef,})) {
    plan skip_all => 'Install Selenium::Remote::WDKeys to run this test';
    exit(0);
}

$driver->title_is("openQA");
is($driver->find_element('#user-action a')->get_text(), 'Login', "noone logged in");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
# but ...

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

# expand user menu
$driver->find_element('#user-action a')->click();
like($driver->find_element_by_id('user-action')->get_text(), qr/Operators Menu/,      'demo is operator');
like($driver->find_element_by_id('user-action')->get_text(), qr/Administrators Menu/, 'demo is admin');

# Demo is admin, so go there
$driver->find_element_by_link_text('Workers')->click();

$driver->title_is("openQA: Workers", "on workers overview");

subtest 'add product' => sub() {
    # go to product first
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Medium types')->click();

    $driver->title_is("openQA: Medium types", "on products");
    wait_for_ajax;
    my $elem    = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(@headers, 6, "6 columns");

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "Distri",   "1st column");
    is((shift @headers)->get_text(), "Version",  "2nd column");
    is((shift @headers)->get_text(), "Flavor",   "3rd column");
    is((shift @headers)->get_text(), "Arch",     "4th column");
    is((shift @headers)->get_text(), "Settings", "5th column");
    is((shift @headers)->get_text(), "Actions",  "6th column");

    # now check one row by example
    $elem    = $driver->find_element('.admintable tbody tr:nth-child(1)');
    @headers = $driver->find_child_elements($elem, 'td');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "opensuse", "distri");
    is((shift @headers)->get_text(), "13.1",     "version");
    is((shift @headers)->get_text(), "DVD",      "flavor");
    is((shift @headers)->get_text(), "i586",     "arch");

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 3, "3 edit buttons/media before");

    is($driver->find_element_by_xpath('//input[@value="New medium"]')->click(), 1, 'new medium');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 4, '4 input fields');
    (shift @fields)->send_keys('sle');      # distri
    (shift @fields)->send_keys('13');       # version
    (shift @fields)->send_keys('DVD');      # flavor
    (shift @fields)->send_keys('arm19');    # arch
    is(scalar @{$driver->find_child_elements($elem, '//textarea', 'xpath')}, 1, '1 textarea');

    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    wait_for_ajax;
    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 4, "4 edit buttons/media afterwards");

    # check the distri name will be lowercase after added a new one
    is($driver->find_element_by_xpath('//input[@value="New medium"]')->click(), 1, 'new medium');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 4, '4 input fields');
    (shift @fields)->send_keys('OpeNSusE');    # distri name has capital letter and many upper/lower case combined
    (shift @fields)->send_keys('13.2');        # version
    (shift @fields)->send_keys('DVD');         # flavor
    (shift @fields)->send_keys('ppc64le');     # arch
    @fields = $driver->find_child_elements($elem, '//textarea', 'xpath');
    is(@fields, 1, '1 textarea');
    (shift @fields)->send_keys("DVD=2\nIOS_MAXSIZE=4700372992");

    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    wait_for_ajax;
    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 5, "5 edit buttons/media afterwards");
};

subtest 'add machine' => sub() {
    # go to machines first
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Machines')->click();

    $driver->title_is("openQA: Machines", "on machines list");
    wait_for_ajax;
    my $elem    = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(@headers, 4, "4 columns");

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "Name",     "1st column");
    is((shift @headers)->get_text(), "Backend",  "2nd column");
    is((shift @headers)->get_text(), "Settings", "3th column");
    is((shift @headers)->get_text(), "Actions",  "4th column");

    # now check one row by example
    $elem    = $driver->find_element('.admintable tbody tr:nth-child(3)');
    @headers = $driver->find_child_elements($elem, 'td');
    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "Laptop_64",                "name");
    is((shift @headers)->get_text(), "qemu",                     "backend");
    is((shift @headers)->get_text(), "LAPTOP=1\nQEMUCPU=qemu64", "cpu");

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 3, "3 edit buttons before");

    is($driver->find_element_by_xpath('//input[@value="New machine"]')->click(), 1, 'new machine');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 2, '2 input fields');
    (shift @fields)->send_keys('HURRA');    # name
    (shift @fields)->send_keys('ipmi');     # backend
    @fields = $driver->find_child_elements($elem, '//textarea', 'xpath');
    is(@fields, 1, '1 textarea');
    (shift @fields)->send_keys("SERIALDEV=ttyS1\nTIMEOUT_SCALE=3\nWORKER_CLASS=64bit-ipmi");    # cpu
    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    wait_for_ajax;

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 4, "4 edit buttons afterwards");
};

subtest 'add test suite' => sub() {
    # go to tests first
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Test suites')->click();

    $driver->title_is("openQA: Test suites", "on test suites");
    wait_for_ajax;
    my $elem    = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(@headers, 4, 'all columns');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "Name",        "1st column");
    is((shift @headers)->get_text(), "Settings",    "2th column");
    is((shift @headers)->get_text(), "Description", "3rd column");
    is((shift @headers)->get_text(), "Actions",     "4th column");

    # now check one row by example
    $elem    = $driver->find_element('.admintable tbody tr:nth-child(1)');
    @headers = $driver->find_child_elements($elem, 'td');

    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @headers)->get_text(), "RAID0", "name");
    is((shift @headers)->get_text(), "DESKTOP=kde\nINSTALLONLY=1\nRAIDLEVEL=0", "DESKTOP");

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 7, "7 edit buttons before");

    is($driver->find_element_by_xpath('//input[@value="New test suite"]')->click(), 1, 'new test suite');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 1, '1 input field');
    (shift @fields)->send_keys('xfce');    # name
    @fields = $driver->find_child_elements($elem, '//textarea', 'xpath');
    is(@fields, 2, '2 textareas');

    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    wait_for_ajax;
    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 8, "8 edit buttons afterwards");

    # can add entry with single, double quotes, special chars
    my ($suiteName, $suiteKey, $suiteValue) = qw(t"e\\st'Suite\' te\'\\st"Ke"y; te'\""stVa;l%&ue);

    is($driver->find_element_by_xpath('//input[@value="New test suite"]')->click(), 1, 'new test suite');
    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my $name     = $driver->find_child_element($elem, '//input[@type="text"]', 'xpath');
    my $settings = $driver->find_child_element($elem, '//textarea',            'xpath');
    $name->send_keys($suiteName);
    $settings->send_keys("$suiteKey=$suiteValue");
    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    # leave the ajax some time
    wait_for_ajax;
# now read data back and compare to original, name and value shall be the same, key sanitized by removing all special chars
    $elem = $driver->find_element('.admintable tbody tr:nth-child(7)')
      ;    # sorting by name so `t"e\st'Suite\'` is supposed to be the 7th element
    is($elem->get_text(), "$suiteName testKey=$suiteValue", 'stored text is the same except key');
    # try to edit and save
    ok($driver->find_child_element($elem, './td/button[@title="Edit"]', 'xpath')->click(), 'editing enabled');
    wait_for_ajax;

    $elem     = $driver->find_element('.admintable tbody tr:nth-child(7)');
    $name     = $driver->find_child_element($elem, './td/input[@type="text"]', 'xpath');
    $settings = $driver->find_child_element($elem, './td/textarea', 'xpath');
    is($name->get_value,    $suiteName,            'suite name edit box match');
    is($settings->get_text, "testKey=$suiteValue", 'textarea matches sanitized key and value');
    ok($driver->find_child_element($elem, '//button[@title="Update"]', 'xpath')->click(), 'editing saved');

    # reread and compare to original
    wait_for_ajax;
    $elem = $driver->find_element('.admintable tbody tr:nth-child(7)');
    is($elem->get_text(), "$suiteName testKey=$suiteValue", 'stored text is the same except key');

    $elem = $driver->find_element('input[type=search]');
    $elem->send_keys("^kde");
    @fields = $driver->find_elements('.admintable tbody tr');
    is(@fields, 1, "search using regex");
};

subtest 'add job group' => sub() {
    # navigate to job groups
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Job groups')->click();
    $driver->title_is("openQA: Job groups", "on groups");

    # check whether all job groups from fixtures are displayed
    my $list_element         = $driver->find_element_by_id('job_group_list');
    my @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'opensuse',      'first parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group present');
    is(@parent_group_entries,                     0,               'only parentless groups present');

    # disable animations to speed up test
    $driver->execute_script('$(\'#add_group_modal\').removeClass(\'fade\'); jQuery.fx.off = true;');

    # add new parentless group, leave name empty (which should lead to error)
    $driver->find_element_by_xpath('//a[@title="Add new job group on top-level"]')->click();
    is($driver->find_element('#create_group_button')->get_attribute('disabled'),
        'true', 'create group submit button is disabled if leave name is empty');
    # now leave group name with blank which also lead to error
    my $groupname = $driver->find_element_by_id('new_group_name');
    $groupname->send_keys('   ');
    is($driver->find_element('#create_group_button')->get_attribute('disabled'),
        'true', 'create group submit button is disabled if leave name as blank');
    is(
        $driver->find_element('#new_group_name')->get_attribute('class'),
        'form-control is-invalid',
        'group name input marked as invalid'
    );
    $groupname->clear();
    $driver->find_element_by_id('create_group_button')->click();
    wait_for_ajax;
    $list_element         = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'opensuse',      'first parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group present');
    is(@parent_group_entries,                     0,               'and also no more parent groups');

    # add new parentless group (dialog should still be open), this time enter a name
    $driver->find_element_by_id('new_group_name')->send_keys('Cool Group');
    $driver->find_element_by_id('create_group_button')->click();
    wait_for_ajax;

    # new group should be present
    $list_element         = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'Cool Group',    'new parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse',      'first parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group from fixtures present');
    is(@parent_group_entries,                     0,               'no further grops present');

    # add new parent group
    $driver->find_element_by_xpath('//a[@title="Add new folder"]')->click();
    $driver->find_element_by_id('new_group_name')->send_keys('New parent group');
    $driver->find_element_by_id('create_group_button')->click();
    wait_for_ajax;

    # check whether parent is present
    $list_element         = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is(@parent_group_entries, 4,
        'now 4 top-level groups present (one is new parent, remaining are parentless job groups)');
    my $new_groups_entry = shift @parent_group_entries;
    is($new_groups_entry->get_text(), 'New parent group', 'new group present');

    # test Drag & Drop: done manually

    # reload page to check whether the changes persist
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Job groups')->click();

    $list_element         = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is(@parent_group_entries, 4,
        'now 4 top-level groups present (one is new parent, remaining are parentless job groups)');
    is((shift @parent_group_entries)->get_text(), 'opensuse',         'first parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test',    'second parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'Cool Group',       'new parentless group present');
    is((shift @parent_group_entries)->get_text(), 'New parent group', 'new group present');
};

subtest 'job property editor' => sub() {
    $driver->title_is('openQA: Job groups', 'on job groups');

    # navigate to editor first
    $driver->find_element_by_link('Cool Group')->click();
    $driver->find_element_by_id('toggle-group-properties')->click();

    subtest 'current/default values present' => sub() {
        is($driver->find_element_by_id('editor-name')->get_value(),              'Cool Group', 'name');
        is($driver->find_element_by_id('editor-size-limit')->get_value(),        '100',        'size limit');
        is($driver->find_element_by_id('editor-keep-logs-in-days')->get_value(), '30',         'keep logs in days');
        is($driver->find_element_by_id('editor-keep-important-logs-in-days')->get_value(),
            '120', 'keep important logs in days');
        is($driver->find_element_by_id('editor-keep-results-in-days')->get_value(), '365', 'keep results in days');
        is($driver->find_element_by_id('editor-keep-important-results-in-days')->get_value(),
            '0', 'keep important results in days');
        is($driver->find_element_by_id('editor-default-priority')->get_value(), '50', 'default priority');
        is($driver->find_element_by_id('editor-carry-over-bugrefs')->is_selected(),
            1, 'bug carry over by default enabled');
        is($driver->find_element_by_id('editor-description')->get_value(), '', 'no description yet');
    };

    subtest 'update group name with empty or blank' => sub {
        my $groupname = $driver->find_element_by_id('editor-name');
        # update group name with empty
        $groupname->send_keys(Selenium::Remote::WDKeys->KEYS->{control}, 'a');
        $groupname->send_keys(Selenium::Remote::WDKeys->KEYS->{backspace});
        is($driver->find_element('#properties p.buttons button.btn-primary')->get_attribute('disabled'),
            'true', 'group properties save button is disabled if leave name is empty');
        is(
            $driver->find_element('#editor-name')->get_attribute('class'),
            'form-control is-invalid',
            'editor name input marked as invalid'
        );
        $driver->refresh();
        $driver->find_element_by_id('toggle-group-properties')->click();

        # update group name with blank
        $groupname = $driver->find_element_by_id('editor-name');
        $groupname->send_keys(Selenium::Remote::WDKeys->KEYS->{control}, 'a');
        $groupname->send_keys('   ');
        is($driver->find_element('#properties p.buttons button.btn-primary')->get_attribute('disabled'),
            'true', 'group properties save button is disabled if leave name is empty');
        is(
            $driver->find_element('#editor-name')->get_attribute('class'),
            'form-control is-invalid',
            'editor name input marked as invalid'
        );
        $driver->refresh();
        $driver->find_element_by_id('toggle-group-properties')->click();
    };

    subtest 'edit some properties' => sub() {
        # those keys will be appended
        $driver->find_element_by_id('editor-name')->send_keys(' has been edited!');
        my $ele = $driver->find_element_by_id('editor-size-limit');
        $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{control}, 'a');
        $ele->send_keys('1000');
        $ele = $driver->find_element_by_id('editor-keep-important-results-in-days');
        $ele->send_keys(Selenium::Remote::WDKeys->KEYS->{control}, 'a');
        $ele->send_keys('500');
        $driver->find_element_by_id('editor-description')->send_keys('Test group');
        is($driver->find_element('#properties p.buttons button.btn-primary')->get_attribute('disabled'),
            undef, 'group properties save button is enabled');
        $driver->find_element_by_id('editor-carry-over-bugrefs')->click();
        $driver->find_element('#properties p.buttons button.btn-primary')->click();
        # ensure there is no race condition, even though the page is reloaded
        wait_for_ajax;

        $driver->refresh();
        $driver->title_is('openQA: Jobs for Cool Group has been edited!', 'new name on title');
        $driver->find_element_by_id('toggle-group-properties')->click();
        is($driver->find_element_by_id('editor-name')->get_value(), 'Cool Group has been edited!', 'name edited');
        is($driver->find_element_by_id('editor-size-limit')->get_value(), '1000', 'size edited');
        is($driver->find_element_by_id('editor-keep-important-results-in-days')->get_value(),
            '500', 'keep important results in days edited');
        is($driver->find_element_by_id('editor-default-priority')->get_value(),
            '50', 'default priority should be the same');
        is($driver->find_element_by_id('editor-carry-over-bugrefs')->is_selected(), 0, 'bug carry over disabled');
        is($driver->find_element_by_id('editor-description')->get_value(), 'Test group', 'description added');
    };

    subtest 'edit the yaml' => sub() {
        $driver->refresh();
        my $form = $driver->find_element_by_id('editor-form');
        ok($form->is_hidden(), 'editor form is hidden');
        $driver->find_element_by_id('toggle-yaml-editor')->click();
        ok($form->is_displayed(),                             'editor form is shown');
        ok($form->child('.progress-indication')->is_hidden(), 'spinner is hidden');
        my $yaml = $driver->execute_script('return editor.doc.getValue();');
        ok($yaml =~ m/Cool Group/, 'YAML was fetched');
        $driver->find_element_by_id('update-template')->click();
        my $result = $form->child('.result');
        wait_for_ajax;
        ok($result->get_text() =~ m/Preview of the YAML/, 'preview shown') or diag explain $result->get_text();

        # Make the YAML invalid
        $driver->execute_script('editor.doc.setValue("invalid: true");');
        $driver->find_element_by_id('update-template')->click();
        wait_for_ajax;
        ok($result->get_text() =~ m/There was a problem applying the changes/, 'error shown');
    };
};

sub is_element_text {
    my ($elements, $expected, $message) = @_;
    my @texts = map {
        my $text = $_->get_text();
        $text =~ s/^\s+|\s+$//g;
        $text;
    } @$elements;
    is_deeply(\@texts, $expected, $message) or diag explain \@texts;
}

subtest 'edit media' => sub() {
    $driver->title_is('openQA: Jobs for Cool Group has been edited!', 'on jobs for Cool Test has been edited!');

    wait_for_ajax;
    $driver->find_element_by_link('Test new medium as part of this group')->click();

    my $select = $driver->find_element_by_id('medium');
    my $option = $driver->find_child_element($select, './option[contains(text(), "sle-13-DVD-arm19")]', 'xpath');
    $option->click();
    $select = $driver->find_element_by_id('machine');
    $option = $driver->find_child_element($select, './option[contains(text(), "HURRA")]', 'xpath');
    $option->click();
    $select = $driver->find_element_by_id('test');
    $option = $driver->find_child_element($select, './option[contains(text(), "xfce")]', 'xpath');
    $option->click();

    $driver->find_element_by_xpath('//input[@type="submit"]')->submit();

    $driver->title_is('openQA: Jobs for Cool Group has been edited!', 'on job groups');
    wait_for_ajax;

    my $td = $driver->find_element('#sle_13_DVD_arm19_xfce_chosen .search-field');
    is('', $td->get_text(), 'field is empty for product 2');
    $driver->mouse_move_to_location(element => $td);
    $driver->button_down();
    wait_for_ajax;

    $driver->send_keys_to_active_element('64bit');
    # as we load this at runtime rather than `use`ing it, we have to
    # access it explicitly like this
    $driver->send_keys_to_active_element(Selenium::Remote::WDKeys->KEYS->{'enter'});
    $driver->find_element('#sle-13-DVD .plus-sign')->click();
    $select = $driver->find_element('#sle-13-DVD .name select');
    ok($select, 'selection shown');

    my @options = $driver->find_elements('#sle-13-DVD tr:first-of-type td:first-of-type option');
    is_element_text(
        \@options,
        ['Select…', 'advanced_kde', 'client1', 'client2', 'kde', 'RAID0', 'server', "t\"e\\st\'Suite\\'", 'textmode'],
        'xfce not selectable because test has already been added before'
    );

    # select advanced_kde option
    $options[1]->click();
    # to check whether the same test isn't selectable twice add another selection and also select advanced_kde
    $driver->find_element('#sle-13-DVD .plus-sign')->click();
    @options = $driver->find_elements('#sle-13-DVD tr:first-of-type td:first-of-type option');
    $options[1]->click();
    # now finalize the selection
    $td = $driver->find_element('#undefined_arm19_new_chosen .search-field');
    $driver->mouse_move_to_location(element => $td);
    $driver->button_down();
    wait_for_ajax;
    $driver->send_keys_to_active_element('64bit');
    $driver->send_keys_to_active_element(Selenium::Remote::WDKeys->KEYS->{'enter'});
    javascript_console_has_no_warnings_or_errors;
    # the test should not be selectable in the first select (which is now second) anymore
    @options = $driver->find_elements('#sle-13-DVD tr:nth-of-type(2) td:first-of-type option');
    is_element_text(
        \@options,
        ['Select…', 'client1', 'client2', 'kde', 'RAID0', 'server', "t\"e\\st\'Suite\\'", 'textmode'],
        'advanced_kde not selectable twice'
    );

    # now reload the page to see if we succeeded
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Job groups')->click();

    $driver->title_is('openQA: Job groups', 'on groups');
    $driver->find_element_by_link('Cool Group has been edited!')->click();

    wait_for_ajax;
    javascript_console_has_no_warnings_or_errors;
    my @picks = $driver->find_elements('.search-choice');
    is_element_text(\@picks, [qw(64bit 64bit HURRA)], 'chosen tests present');
};

sub get_cell_contents {
    my ($row) = @_;
    return [map { $_->get_text() } $driver->find_elements($row . ' td')];
}

subtest 'asset list' => sub {
    # add the file for asset 4 actually in the file system to check deletion
    my $asset_path
      = catfile($OpenQA::Utils::assetdir, 'iso', 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso');
    open(my $fh, '>', $asset_path);
    print $fh "ISO\n";
    close($fh);
    ok(-e $asset_path, 'dummy asset present at ' . $asset_path);

    my $asset_table_url = '/admin/assets?force_refresh=1';
    $driver->get($asset_table_url);
    $driver->title_is("openQA: Assets", "on asset");
    wait_for_ajax;

    ok(-f 't/data/openqa/webui/cache/asset-status.json', 'cache file created');

    # table of assets
    is_deeply(
        get_cell_contents('tr:nth-child(4)'),
        ['iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso', '99947', '4 byte', '1001'],
        'asset with unknown last use and size'
    );
    is_deeply(
        get_cell_contents('tr:nth-child(2)'),
        ['iso/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso', '99963', '4 byte', '1001 1002'],
        'asset with last use'
    );

    # assets by group
    my @assets_by_group = map { $_->get_text() } $driver->find_elements('#assets-by-group > li');
    if (scalar(@assets_by_group) > 0 && $assets_by_group[0] =~ qr/Untracked.*/) {
        note('ignoring untracked assets in your checkout (likely created by previous tests)');
        splice(@assets_by_group, 0, 1);
    }
    is_deeply(
        \@assets_by_group,
        ["opensuse test\n16 byte / 100 GiB", "opensuse\n16 byte / 100 GiB"],
        'groups of "assets by group"'
    );
    $driver->click_element_ok('#group-1001-checkbox + label', 'css');
    is_deeply(
        [map { $_->get_text() } $driver->find_elements('#group-1001-checkbox ~ ul li')],
        [
            "iso/openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso\n4 byte",
            "iso/openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso\n4 byte",
            "iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso\n4 byte",
            "hdd/fixed/openSUSE-13.1-x86_64.hda\n4 byte"
        ],
        'assets of "assets by group"'
    );

    # delete one of the assets
    my $asset4_td = $driver->find_element('tr:nth-child(6) td:first-child');
    my $asset4_a  = $driver->find_child_element($asset4_td, 'a');
    is($asset4_td->get_text(), 'iso/openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso')
      and $asset4_a->click();
    wait_for_ajax;

    # FIXME/caveat: since the table doesn't show livedata the deletion is currently immediately
    #               visible

    ok(!-e $asset_path, 'dummy asset should have been removed');
    unlink($asset_path);
};

kill_driver();
done_testing();
