#!/usr/bin/env perl
# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use File::Path qw(remove_tree);
use File::Spec::Functions 'catfile';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::SeleniumTest;
use OpenQA::Test::Case;
use OpenQA::Utils 'assetdir';
use Date::Format 'time2str';
use IO::Socket::INET;

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional qw(can_load);

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl 04-products.pl'
);

my $job_groups = $schema->resultset('JobGroups');
my $assets = $schema->resultset('Assets');
$assets->find(2)->update(
    {
        size => 4096,
        last_use_job_id => 99962,
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
    });

$job_groups->find(1002)->update({exclusively_kept_asset_size => 4096});

driver_missing unless my $driver = call_driver;

# DO NOT MOVE THIS INTO A 'use' FUNCTION CALL! It will cause the tests
# to crash if the module is unavailable
plan skip_all => 'Install Selenium::Remote::WDKeys to run this test'
  unless can_load(modules => {'Selenium::Remote::WDKeys' => undef,});

$driver->title_is("openQA");
is($driver->find_element('#user-action a')->get_text(), 'Login', "no one logged in");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
# but ...

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

# expand user menu
$driver->find_element('#user-action a')->click();
like($driver->find_element_by_id('user-action')->get_text(), qr/Operators Menu/, 'demo is operator');
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
    my $elem = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(@headers, 6, '6 columns');
    is((shift @headers)->get_text(), 'Distri', '1st column');
    is((shift @headers)->get_text(), 'Version', '2nd column');
    is((shift @headers)->get_text(), 'Flavor', '3rd column');
    is((shift @headers)->get_text(), 'Arch', '4th column');
    is((shift @headers)->get_text(), 'Settings', '5th column');
    is((shift @headers)->get_text(), 'Actions', '6th column');

    # now check one row by example
    $elem = $driver->find_element('.admintable tbody tr:nth-child(1)');
    my @cells = $driver->find_child_elements($elem, 'td');
    is((shift @cells)->get_text(), "opensuse", "distri");
    is((shift @cells)->get_text(), "13.1", "version");
    is((shift @cells)->get_text(), "DVD", "flavor");
    is((shift @cells)->get_text(), "i586", "arch");

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 3, "3 edit buttons/media before");

    is($driver->find_element_by_xpath('//input[@value="New medium"]')->click(), 1, 'new medium');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 4, '4 input fields');
    (shift @fields)->send_keys('sle');    # distri
    (shift @fields)->send_keys('13');    # version
    (shift @fields)->send_keys('DVD');    # flavor
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
    (shift @fields)->send_keys('13.2');    # version
    (shift @fields)->send_keys('DVD');    # flavor
    (shift @fields)->send_keys('ppc64le');    # arch
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
    my $elem = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    is(@headers, 4, '4 columns');
    is((shift @headers)->get_text(), 'Name', '1st column');
    is((shift @headers)->get_text(), 'Backend', '2nd column');
    is((shift @headers)->get_text(), 'Settings', '3th column');
    is((shift @headers)->get_text(), 'Actions', '4th column');

    # now check one row by example
    $elem = $driver->find_element('.admintable tbody tr:nth-child(3)');
    my @cells = $driver->find_child_elements($elem, 'td');
    # the headers are specific to our fixtures - if they change, we have to adapt
    is((shift @cells)->get_text(), "Laptop_64", "name");
    is((shift @cells)->get_text(), "qemu", "backend");
    is((shift @cells)->get_text(), "LAPTOP=1\nQEMUCPU=qemu64", "cpu");

    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 3, "3 edit buttons before");

    is($driver->find_element_by_xpath('//input[@value="New machine"]')->click(), 1, 'new machine');

    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 2, '2 input fields');
    (shift @fields)->send_keys('HURRA');    # name
    (shift @fields)->send_keys('ipmi');    # backend
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
    my $elem = $driver->find_element('.admintable thead tr');
    my @headers = $driver->find_child_elements($elem, 'th');
    my $column_count = 4;
    is(@headers, $column_count, 'all columns');
    is((shift @headers)->get_text(), 'Name', '1st column');
    is((shift @headers)->get_text(), 'Settings', '2th column');
    is((shift @headers)->get_text(), 'Description', '3rd column');
    is((shift @headers)->get_text(), 'Actions', '4th column');

    # check whether all rows/cells are present and check some cell values
    $elem = $driver->find_element('.admintable tbody');
    my @cells = $driver->find_child_elements($elem, 'td');

    is(scalar @cells, 7 * $column_count, 'all seven rows present');
    is($cells[0 * $column_count + 0]->get_text(), 'RAID0', 'name');
    is($cells[0 * $column_count + 1]->get_text(), "DESKTOP=kde\nINSTALLONLY=1\nRAIDLEVEL=0", 'settings');
    is($cells[0 * $column_count + 2]->get_text(), '', 'description');
    is($cells[1 * $column_count + 0]->get_text(), 'advanced_kde', 'name (2nd row)');
    is($cells[1 * $column_count + 2]->get_text(), 'See kde for simple test', 'description (2nd row)');
    is(scalar @{$driver->find_elements('//button[@title="Edit"]', 'xpath')}, 7, '7 edit buttons before');

    # search (settings taken into account, cleared when adding new row)
    my $search_input = $driver->find_element('.dataTables_filter input');
    $search_input->send_keys('DESKTOP=kdeINSTALLONLY=1');
    @cells = $driver->find_child_elements($elem, 'td');
    is(scalar @cells, 1 * $column_count, 'everything filtered out but one row');
    is($cells[0 * $column_count + 0]->get_text(), 'RAID0', 'remaining row has correct name');
    is(
        $cells[0 * $column_count + 1]->get_text(),
        "DESKTOP=kde\nINSTALLONLY=1\nRAIDLEVEL=0",
        'remaining row has correct settings'
    );

    is($driver->find_element_by_xpath('//input[@value="New test suite"]')->click(), 1, 'new test suite');
    is(element_prop_by_selector('.dataTables_filter input'), '((DESKTOP=kdeINSTALLONLY=1)|(new row))',
        'search cleared');
    @cells = $driver->find_child_elements($elem, 'td');
    is(scalar @cells, 2 * $column_count, 'filtered row and empty row present');
    is($cells[0 * $column_count + 0]->get_text(), 'RAID0', 'filtered row has correct name');
    is($cells[1 * $column_count + 0]->get_text(), '', 'name of new row is empty');
    is($cells[1 * $column_count + 1]->get_text(), '', 'settings of new row are empty');
    is($cells[1 * $column_count + 2]->get_text(), '', 'description of new row is empty');
    my @fields = $driver->find_child_elements($elem, '//input[@type="text"]', 'xpath');
    is(@fields, 1, '1 input field');
    (shift @fields)->send_keys('xfce');    # name
    @fields = $driver->find_child_elements($elem, '//textarea', 'xpath');
    is(@fields, 2, '2 textareas');

    is($driver->find_element_by_xpath('//button[@title="Add"]')->click(), 1, 'added');
    wait_for_ajax;
    is(@{$driver->find_elements('//button[@title="Edit"]', 'xpath')},
        2, '2 edit buttons afterwards (for row matching previously entered filter and submitted row)');

    # clear admin table search
    $driver->execute_script('window.adminTable.search("")');

    # can add entry with single, double quotes, special chars
    my ($suiteName, $suiteKey, $suiteValue) = qw(t"e\\st'Suite\' te\'\\st"Ke"y; te'\""stVa;l%&ue);

    is($driver->find_element_by_xpath('//input[@value="New test suite"]')->click(), 1, 'new test suite');
    $elem = $driver->find_element('.admintable tbody tr:last-child');
    is($elem->get_text(), '', 'new row empty');
    $driver->find_child_element($elem, '//input[@type="text"]', 'xpath')->send_keys($suiteName);
    $driver->find_child_element($elem, '//textarea', 'xpath')->send_keys("$suiteKey=$suiteValue");
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

    $elem = $driver->find_element('.admintable tbody tr:nth-child(7) td textarea');
    is(element_prop_by_selector('.admintable tbody tr:nth-child(7) td input[type="text"]'),
        $suiteName, 'suite name edit box match');
    is($elem->get_text, "testKey=$suiteValue", 'textarea matches sanitized key and value');
    ok($driver->find_child_element($elem, '//button[@title="Update"]', 'xpath')->click(), 'editing saved');

    # reread and compare to original
    wait_for_ajax;
    $elem = $driver->find_element('.admintable tbody tr:nth-child(7)');
    is($elem->get_text(), "$suiteName testKey=$suiteValue", 'stored text is the same except key');

    $elem = $driver->find_element('#test-suites_filter input[type=search]');
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
    my $list_element = $driver->find_element_by_id('job_group_list');
    my @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'opensuse', 'first parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group present');
    is(@parent_group_entries, 0, 'only parentless groups present');

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
    $list_element = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'opensuse', 'first parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group present');
    is(@parent_group_entries, 0, 'and also no more parent groups');

    # add new parentless group (dialog should still be open), this time enter a name
    $driver->find_element_by_id('new_group_name')->send_keys('Cool Group');
    $driver->find_element_by_id('create_group_button')->click();
    wait_for_ajax;

    # new group should be present
    $list_element = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is((shift @parent_group_entries)->get_text(), 'Cool Group', 'new parentless group present');
    is((shift @parent_group_entries)->get_text(), 'opensuse', 'first parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group from fixtures present');
    is(@parent_group_entries, 0, 'no further grops present');

    # add new parent group
    $driver->find_element_by_xpath('//a[@title="Add new folder"]')->click();
    $driver->find_element_by_id('new_group_name')->send_keys('New parent group');
    $driver->find_element_by_id('create_group_button')->click();
    wait_for_ajax;

    # check whether parent is present
    $list_element = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is(@parent_group_entries, 4,
        'now 4 top-level groups present (one is new parent, remaining are parentless job groups)');
    my $new_groups_entry = shift @parent_group_entries;
    is($new_groups_entry->get_text(), 'New parent group', 'new group present');

    # test Drag & Drop: done manually

    # reload page to check whether the changes persist
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Job groups')->click();

    $list_element = $driver->find_element_by_id('job_group_list');
    @parent_group_entries = $driver->find_child_elements($list_element, 'li');
    is(@parent_group_entries, 4,
        'now 4 top-level groups present (one is new parent, remaining are parentless job groups)');
    is((shift @parent_group_entries)->get_text(), 'opensuse', 'first parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'opensuse test', 'second parentless group from fixtures present');
    is((shift @parent_group_entries)->get_text(), 'Cool Group', 'new parentless group present');
    is((shift @parent_group_entries)->get_text(), 'New parent group', 'new group present');
};

subtest 'job property editor' => sub() {
    $driver->title_is('openQA: Job groups', 'on job groups');

    # navigate to editor first
    $driver->find_element_by_link('Cool Group')->click();
    $driver->find_element_by_id('toggle-group-properties')->click();

    subtest 'current/default values present' => sub() {
        is element_prop('editor-name'), 'Cool Group', 'name';
        is element_prop('editor-size-limit'), '', 'size limit';
        is element_prop('editor-size-limit', 'placeholder'), 'default, configured to 100', 'size limit';
        is element_prop('editor-keep-logs-in-days'), '30', 'keep logs in days';
        is element_prop('editor-keep-important-logs-in-days'), '120', 'keep important logs in days';
        is element_prop('editor-keep-results-in-days'), '365', 'keep results in days';
        is element_prop('editor-keep-important-results-in-days'), '0', 'keep important results in days';
        is element_prop('editor-default-priority'), '50', 'default priority';
        ok element_prop('editor-carry-over-bugrefs', 'checked'), 'bug carry over by default enabled';
        is element_prop('editor-description'), '', 'no description yet';
    };

    subtest 'update group name with empty or blank' => sub {
        my $groupname = $driver->find_element_by_id('editor-name');
        # update group name with empty
        $groupname->send_keys(Selenium::Remote::WDKeys->KEYS->{control}, 'a');
        $groupname->send_keys(Selenium::Remote::WDKeys->KEYS->{backspace});
        is($driver->find_element('#properties p.buttons button.btn-primary')->get_attribute('disabled'),
            'true', 'group properties save button is disabled if name is left empty');
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
            'true', 'group properties save button is disabled if name is blank');
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
        wait_for_ajax(msg => 'ensure there is no race condition, even though the page is reloaded');
        $driver->refresh();
        $driver->title_is('openQA: Job templates for Cool Group has been edited!', 'new name on title');
        $driver->find_element_by_id('toggle-group-properties')->click();
        is element_prop('editor-name'), 'Cool Group has been edited!', 'name edited';
        is element_prop('editor-size-limit'), '1000', 'size edited';
        is element_prop('editor-keep-important-results-in-days'), '500', 'keep important results in days edited';
        is element_prop('editor-default-priority'), '50', 'default priority should be the same';
        ok !element_prop('editor-carry-over-bugrefs', 'checked'), 'bug carry over disabled';
        is element_prop('editor-description'), 'Test group', 'description added';

        # clear asset size limit again
        $driver->find_element_by_id('clear-size-limit-button')->click();
        $driver->find_element('#properties p.buttons button.btn-primary')->click();
        $driver->refresh();
        is element_prop('editor-size-limit'), '', 'size edited';
    };
};

subtest 'edit job templates' => sub() {
    subtest 'open YAML editor for new group with no templates' => sub {
        $driver->get('/admin/job_templates/1003');
        wait_for_ajax;
        my $form = $driver->find_element_by_id('editor-form');
        ok($form->is_displayed(), 'editor form is shown by default');
        ok($form->child('.progress-indication')->is_hidden(), 'spinner is hidden');
        is(scalar @{$driver->find_elements('Test new medium as part of this group', 'link_text')},
            0, 'link to add a new medium (via legacy editor) not shown');
        my $yaml = $driver->execute_script('return editor.doc.getValue();');
        like($yaml, qr/products:\s*{}.*scenarios:\s*{}/s, 'default YAML was fetched') or diag explain $yaml;
    };

    my ($yaml, $form);
    subtest 'open YAML editor for legacy group' => sub {
        $driver->get('/admin/job_templates/1001');
        $form = $driver->find_element_by_id('editor-form');
        ok($form->is_hidden(), 'editor form is not shown by default');
        $driver->find_element_by_id('toggle-yaml-editor')->click();
        wait_for_ajax;
        ok($form->is_displayed(), 'editor form is shown');
        ok($form->child('.progress-indication')->is_hidden(), 'spinner is hidden');
        $yaml = $driver->execute_script('return editor.doc.getValue();');
        like($yaml, qr/scenarios:/, 'YAML was fetched') or diag explain $yaml;
    };

    # Preview
    $driver->find_element_by_id('preview-template')->click();
    my $result = $form->child('.result');
    wait_for_ajax;
    like($result->get_text(), qr/Preview of the changes/, 'preview shown') or diag explain $result->get_text();
    like($result->get_text(), qr/No changes were made!/, 'preview, nothing changed')
      or diag explain $result->get_text();

    # Expansion
    $driver->find_element_by_id('expand-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/Result of expanding the YAML/, 'expansion shown') or diag explain $result->get_text();
    like($result->get_text(), qr/settings: \{\}/, 'expanded YAML has empty settings')
      or diag explain $result->get_text();
    unlike($result->get_text(), qr/defaults:/, 'expanded YAML has no defaults')
      or diag explain $result->get_text();

    # Save
    $driver->find_element_by_id('save-template')->click();
    $result = $form->child('.result');
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'saving confirmed') or diag explain $result->get_text();
    like($result->get_text(), qr/No changes were made!/, 'preview, nothing changed')
      or diag explain $result->get_text();

    # Make changes to existing YAML
    $yaml .= "    - advanced_kde_low_prio:\n";
    $yaml .= "        testsuite: advanced_kde\n";
    $yaml .= "        priority: 11\n";
    $yaml =~ s/\n/\\n/g;
    $driver->execute_script("editor.doc.setValue(\"$yaml\");");
    $driver->find_element_by_id('preview-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/Preview of the changes/, 'preview shown') or diag explain $result->get_text();
    ok(index($result->get_text(), '@@ -42,3 +42,6 @@') != -1, 'diff of changes shown')
      or diag explain $result->get_text();
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'saving confirmed') or diag explain $result->get_text();
    ok(index($result->get_text(), '@@ -42,3 +42,6 @@') != -1, 'diff of changes shown')
      or diag explain $result->get_text();

    # No changes
    $driver->find_element_by_id('preview-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/Preview of the changes/, 'preview shown') or diag explain $result->get_text();
    like($result->get_text(), qr/No changes were made!/, 'preview, nothing changed')
      or diag explain $result->get_text();
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'saving confirmed') or diag explain $result->get_text();
    like($result->get_text(), qr/No changes were made!/, 'saved, nothing changed') or diag explain $result->get_text();

    # Legacy UI is hidden and no longer available
    ok($driver->find_element_by_id('toggle-yaml-editor')->is_hidden(), 'editor toggle hidden');
    ok($driver->find_element_by_id('media')->is_hidden(), 'media editor hidden');

    # More changes on top of the previous ones
    $yaml .= "    - advanced_kde_high_prio:\n";
    $yaml .= "        testsuite: advanced_kde\n";
    $yaml .= "        priority: 99\n";
    $yaml =~ s/\n/\\n/g;
    $driver->execute_script("editor.doc.setValue(\"$yaml\");");
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'saving confirmed') or diag explain $result->get_text();

    # Empty the editor
    $driver->execute_script("editor.doc.setValue('');");
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'saving confirmed') or diag explain $result->get_text();
    $yaml = $driver->execute_script('return editor.doc.getValue();');
    is($yaml, "products: {}\nscenarios: {}\n", 'YAML was reset to default') or diag explain $yaml;

    my $first_tab = $driver->get_current_window_handle();
    # Make changes in a separate tab
    my $second_tab = open_new_tab($driver->get_current_url());
    $driver->switch_to_window($second_tab);
    $form = $driver->find_element_by_id('editor-form');
    $result = $form->child('.result');
    $yaml .= " # additional comment";
    my $jsyaml = $yaml =~ s/\n/\\n/gr;
    $driver->execute_script("editor.doc.setValue(\"$jsyaml\");");
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/YAML saved!/, 'second tab saved') or diag explain $result->get_text();
    my $saved_yaml = $driver->execute_script('return editor.doc.getValue();');
    is($saved_yaml, "$yaml\n", 'YAML got a final linebreak') or diag explain $yaml;
    # Try and save, after the database has already been modified
    $driver->switch_to_window($first_tab);
    $form = $driver->find_element_by_id('editor-form');
    $result = $form->child('.result');
    $jsyaml .= " # one more comment\\n";
    $driver->execute_script("editor.doc.setValue(\"$jsyaml\");");
    $driver->find_element_by_id('save-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/Template was modified/, 'conflict reported') or diag explain $result->get_text();

    # Make the YAML invalid
    $driver->execute_script('editor.doc.setValue("invalid: true");');
    $driver->find_element_by_id('preview-template')->click();
    wait_for_ajax;
    like($result->get_text(), qr/There was a problem applying the changes/, 'error shown');

    # Group properties remain accessible
    $driver->find_element_by_id('toggle-group-properties')->click();
    ok($driver->find_element_by_id('editor-name')->is_displayed(), 'Group name can be edited');
    $driver->refresh();
    wait_for_ajax;
    $driver->find_element_by_id('toggle-group-properties')->click();
    ok($driver->find_element_by_id('editor-name')->is_displayed(), 'Group name can still be edited after refresh');
};

sub get_cell_contents {
    my ($row) = @_;
    return [map { $_->get_text() } $driver->find_elements($row . ' td')];
}

subtest 'asset list' => sub {
    # add the file for asset 4 actually in the file system to check deletion
    my $asset_path = catfile(assetdir(), 'iso', 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso');
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
    my $asset4_a = $driver->find_child_element($asset4_td, 'a');
    is($asset4_td->get_text(), 'iso/openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso')
      and $asset4_a->click();
    wait_for_ajax;

    like(
        $driver->find_element("div#flash-messages .alert span")->get_text,
        qr/The asset was deleted successfully/,
        'delete asset successfully'
    );
    $asset4_a->click();
    wait_for_ajax;
    is(
        $driver->find_element("div#flash-messages .alert-danger span")->get_text,
        'The asset might have already been removed and only the cached view has not been updated yet.',
        'The asset has been removed'
    );

    # FIXME/caveat: since the table doesn't show livedata the deletion is currently immediately
    #               visible

    ok(!-e $asset_path, 'dummy asset should have been removed');
    unlink($asset_path);
};

sub api_keys_tbody { $driver->find_element_by_id('api-keys-tbody') }

subtest 'Manage API keys' => sub {
    my $tbody;

    subtest 'view keys' => sub {
        $driver->get('/api_keys');
        $tbody = api_keys_tbody;
        like($tbody->get_text, qr/1234567890ABCDEF/, 'default API key present');
    };

    subtest 'delete key' => sub {
        $driver->find_child_element($tbody, 'a[title=Delete]')->click;
        unlike(api_keys_tbody->get_text, qr/1234567890ABCDEF/, 'default API key present');
        like($driver->find_element_by_id('flash-messages')->get_text, qr/API key delete/, 'flash message for deletion');
    };

    subtest 'create key with expiration date' => sub {
        $driver->find_element('#api-keys-form input[type=submit]')->click;
        is(scalar @{$driver->find_child_elements($tbody = api_keys_tbody, 'tr')}, 1, 'exactly one key present');
        like($tbody->get_text, qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, 'new key has expiration date');
    };

    subtest 'create key without expiration date' => sub {
        unlike($tbody->get_text, qr/never/, 'no key without expiration date present so far');
        $driver->find_element_by_id('expiration')->click;
        $driver->find_element('#api-keys-form input[type=submit]')->click;
        is(scalar @{$driver->find_child_elements($tbody = api_keys_tbody, 'tr')}, 2, 'two keys present now');
        like($tbody->get_text, qr/never/, 'new key has expiration date');
    };
};

kill_driver();
done_testing();
