#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

# Increase timeout in case CI gets slower than normal
$ENV{MOJO_INACTIVITY_TIMEOUT} = 120;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Encode 'encode_utf8';
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '120';
use OpenQA::Test::Case;
use OpenQA::Test::Utils qw(assume_all_assets_exist shared_hash prepare_clean_needles_dir prepare_default_needle);
use Cwd 'abs_path';
use Mojo::File qw(path tempdir);
use Mojo::JSON 'decode_json';
use Date::Format 'time2str';
use POSIX 'strftime';

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl 04-products.pl 05-job_modules.pl'
);

use OpenQA::SeleniumTest;

sub decode_utf8_json {
    my ($json_string) = @_;
    return decode_json(encode_utf8($json_string));
}

sub create_running_job_for_needle_editor {
    $schema->resultset('Jobs')->create(
        {
            id => 99980,
            result => 'none',
            state => 'running',
            priority => 35,
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            t_finished => undef,
            TEST => 'kde',
            BUILD => '0091',
            DISTRI => 'opensuse',
            FLAVOR => 'DVD',
            MACHINE => '64bit',
            VERSION => '13.1',
            result_dir => '00099963-opensuse-13.1-DVD-x86_64-Build0091-kde',
            jobs_assets => [{asset_id => 2},],
            modules => [
                {
                    script => 'tests/installation/installation_overview.pm',
                    category => 'installation',
                    name => 'installation_overview',
                    result => 'passed',
                },
                {
                    script => 'tests/installation/installation_mode.pm',
                    category => 'installation',
                    name => 'installation_mode',
                    result => 'running',
                },
            ]});
    $schema->resultset('Workers')->create(
        {
            host => 'dummy',
            instance => 1,
            properties => [{key => 'JOBTOKEN', value => 'token99980'}],
            job_id => 99980,
        });
    assume_all_assets_exist;
}

create_running_job_for_needle_editor;

# enable use of Git (via a config file to affect all apps forked by call_driver) but mock it
$ENV{OPENQA_CONFIG} = my $config_dir = tempdir;
$config_dir->child('openqa.ini')->spurt("[global]\nscm = git");
shared_hash {};
my $git_mock = Test::MockModule->new('OpenQA::Git');
$git_mock->redefine(commit => sub ($self, $args) { shared_hash $args; return undef });

driver_missing unless my $driver = call_driver();

# We need a fake Minion worker because not having an active worker results in error messages from the UI
my $fake_app = Mojo::Server->new->build_app('OpenQA::WebAPI');
my $minion = $fake_app->minion;
my $fake_worker = $minion->worker->register;

# prepare clean needles directory, create default 'inst-timezone' needle
my $dir = prepare_clean_needles_dir;
my $needle_json_file = prepare_default_needle($dir);

my $elem;
my $decode_textarea;

sub goto_editor_for_installer_timezone {
    $driver->get('/tests/99946');
    is(
        $driver->get_title(),
        'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results',
        'tests/99946 followed'
    );
    # init the preview
    wait_for_ajax(with_minion => $minion);

    # init the diff
    $driver->find_element_by_xpath('//a[@href="#step/installer_timezone/1"]')->click();
    wait_for_ajax(with_minion => $minion);

    $driver->find_element('.step_actions .create_new_needle')->click();
}

sub add_needle_tag {
    my $tagname = shift || 'test-newtag';
    $elem = $driver->find_element_by_id('newtag');
    $elem->send_keys($tagname);
    $driver->find_element_by_id('tag_add_button')->click();
    wait_for_ajax(with_minion => $minion);
    is($driver->find_element_by_xpath("//input[\@value=\"$tagname\"]")->is_selected(),
        1, "new tag found and was checked");
}

sub add_workaround_property() {
    $driver->find_element_by_id('property_workaround')->click();
    $driver->find_element_by_id('input_workaround_desc')->send_keys('bsc#123456 - this is a täst');
    wait_for_ajax(with_minion => $minion);
    ok element_prop('property_workaround', 'checked'), 'workaround property selected';
    ok $driver->find_element_by_id('input_workaround_desc')->is_displayed, 'workaround description displayed';
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
    wait_for_ajax(with_minion => $minion);
}

sub change_needle_value {
    my ($xoffset, $yoffset) = @_;

    my $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    ok($decode_new_textarea->{area}, 'json has area');
    ok($decode_new_textarea->{properties}, 'json has properties');
    ok($decode_new_textarea->{tags}, 'json has tags');

    create_needle($xoffset, $yoffset);

    # check the value of textarea again
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is($decode_new_textarea->{area}[0]->{xpos}, $xoffset, 'new xpos correct');
    is($decode_new_textarea->{area}[0]->{ypos}, $yoffset, 'new ypos correct');
    is($decode_new_textarea->{area}[0]->{click_point}, undef, 'initially no click_point');

    # test match type
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is($decode_new_textarea->{area}[0]->{type}, "match", "type is match");
    $driver->double_click;    # the match type change to exclude
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is($decode_new_textarea->{area}[0]->{type}, "exclude", "type is exclude");
    $driver->double_click;    # the match type change to ocr
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is($decode_new_textarea->{area}[0]->{type}, "ocr", "type is ocr");
    $driver->double_click;    # the match type change back to match

    unlike($driver->find_element_by_id('change-match')->get_attribute('class'),
        qr/disabled/, "match level now enabled");

    # test match level
    $driver->find_element_by_id('change-match')->click();
    wait_for_ajax(with_minion => $minion);
    my $dialog = $driver->find_element_by_id('change-match-form');
    is $driver->find_element_by_id('set_match')->is_displayed(), 1, 'found set button';
    is element_prop('match'), '96', 'default match level is 96';
    $driver->find_element_by_xpath('//input[@id="match"]')->clear;
    $driver->find_element_by_xpath('//input[@id="match"]')->send_keys('99');
    is element_prop('match'), '99', 'set match level to 99';
    $driver->find_element_by_id('set_match')->click;
    is $driver->find_element_by_id('change-match-form')->is_hidden, 1, 'match level form closed';
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is $decode_new_textarea->{area}[0]->{match}, 99, 'match level is 99 now';

    # test adding click point
    $driver->find_element_by_id('toggle-click-coordinates')->click();
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    my $area = $decode_new_textarea->{area}[0];
    is_deeply(
        $area->{click_point},
        {
            xpos => $area->{width} / 2,
            ypos => $area->{height} / 2,
        },
        'click_point added with coordinates in the center of the needle by default'
    );

    # test removing click point
    $driver->find_element_by_id('toggle-click-coordinates')->click();
    $decode_new_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    is($decode_new_textarea->{area}[0]->{click_point}, undef, 'click_point removed');
}

sub overwrite_needle {
    my ($needlename) = @_;

    # remove animation from modal to speed up test
    $driver->execute_script('$(\'#modal-overwrite\').removeClass(\'fade\');');

    $driver->find_element_by_id('needleeditor_name')->clear();
    is element_prop('needleeditor_name'), '', 'needle name input clean up';
    $driver->find_element_by_id('needleeditor_name')->send_keys($needlename);
    is element_prop('needleeditor_name'), $needlename, 'new needle name inputed';
    $driver->find_element_by_id('save')->click();
    wait_for_ajax(with_minion => $minion);
    my $diag;
    $diag = $driver->find_element_by_id('modal-overwrite');
    is($driver->find_child_element($diag, '.modal-title', 'css')->is_displayed(), 1, "overwrite dialog shown");
    is(
        $driver->find_child_element($diag, '.modal-title', 'css')->get_text(),
        "Sure to overwrite test-newneedle?",
        "Needle part of the title"
    );

    $driver->find_element_by_id('modal-overwrite-confirm')->click();

    wait_for_ajax(with_minion => $minion);
    is(
        $driver->find_element('#flash-messages span')->get_text(),
        'Needle test-newneedle created/updated - restart job',
        'highlight appears correct'
    );
    ok(-f "$dir/$needlename.json", "$needlename.json overwritten");

    $driver->find_element('#flash-messages span a')->click();
    # restart is an ajax call, for some reason the check/sleep interval must be at least 1 sec for this call
    wait_for_ajax(interval => 1, minion => $minion);
    is(
        $driver->get_title(),
        'openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results',
        "no longer on needle editor"
    );
}

sub check_flash_for_saving_logpackages {
    wait_for_ajax(with_minion => $minion);
    like(
        $driver->find_element('#flash-messages span')->get_text(),
        qr/Needle logpackages-before-package-selection-\d{8} created\/updated - restart job/,
        'highlight appears correct'
    );
    $driver->find_element('#flash-messages .close')->click();
}



# the actual test starts here

subtest 'Open needle editor for installer_timezone' => sub {
    $driver->title_is('openQA', 'on main page');
    $driver->find_element_by_link_text('Login')->click();
    # we're back on the main page
    $driver->title_is('openQA', 'back on main page');

    is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

    goto_editor_for_installer_timezone();

    # no warnings about missing/bad needles present (yet)
    my @warnings = $driver->find_elements('#editor_warnings', 'css');
    is(scalar @warnings, 0, 'no warnings');
};

subtest 'Needle editor layout' => sub {
    wait_for_ajax(with_minion => $minion);

    # layout check
    is element_prop('tags_select'), 'inst-timezone-text', 'inst-timezone tags selected';
    is element_prop('image_select'), 'screenshot', 'screenshot background selected';
    is element_prop('area_select'), 'inst-timezone-text', 'inst-timezone areas selected';
    ok element_prop('take_matches', 'checked'), '"take matches" selected by default';

    # check needle suggested name
    my $today = strftime("%Y%m%d", gmtime(time));
    is element_prop('needleeditor_name'), "inst-timezone-text-$today", "has correct needle name";

    # ENV-VIDEOMODE-text and inst-timezone tag are selected
    is($driver->find_element_by_xpath('//input[@value="inst-timezone"]')->is_selected(), 1, "tag selected");

    # workaround property isn't selected
    is element_prop('property_workaround', 'checked'), 0, 'workaround property unselected';
    is $driver->find_element_by_id('input_workaround_desc')->is_displayed(), 0, 'workaround description not displayed';

    $decode_textarea = decode_utf8_json(element_prop('needleeditor_textarea'));
    # the value already defined in t/data/default-needle.json
    is(@{$decode_textarea->{area}}, 2, 'exclude areas always present');
    is($decode_textarea->{area}[0]->{xpos}, 0, 'xpos correct');
    is($decode_textarea->{area}[0]->{ypos}, 0, 'ypos correct');
    is($decode_textarea->{area}[0]->{width}, 384, 'width correct');
    is($decode_textarea->{area}[0]->{height}, 217, 'height correct');
    is($decode_textarea->{area}[0]->{type}, 'match', 'type correct');
    is($decode_textarea->{area}[1]->{xpos}, 175, 'xpos correct');
    is($decode_textarea->{area}[1]->{ypos}, 45, 'ypos correct');
    is($decode_textarea->{area}[1]->{width}, 160, 'width correct');
    is($decode_textarea->{area}[1]->{height}, 60, 'height correct');
    is($decode_textarea->{area}[1]->{type}, 'exclude', 'type correct');

    # toggling 'take matches' has no effect
    $driver->find_element_by_xpath('//input[@value="inst-timezone"]')->click();
    is @{decode_utf8_json(element_prop('needleeditor_textarea'))->{area}}, 2, 'exclude areas always present';
    $driver->find_element_by_xpath('//input[@value="inst-timezone"]')->click();
    is @{decode_utf8_json(element_prop('needleeditor_textarea'))->{area}}, 2, 'no duplicated exclude areas present';
};

my $needlename = 'test-newneedle';
my $xoffset = my $yoffset = 200;

subtest 'Create new needle' => sub {
    add_needle_tag();

    # check needle name input
    $driver->find_element_by_id('needleeditor_name')->clear();
    is element_prop('needleeditor_name'), '', 'needle name input clean up';
    $driver->find_element_by_id('needleeditor_name')->send_keys($needlename);
    is element_prop('needleeditor_name'), $needlename, 'new needle name inputed';

    # select 'Copy areas from: None'
    $driver->execute_script('$("#area_select option").eq(0).prop("selected", true)');
    $driver->find_element_by_id('save')->click();
    wait_for_ajax(with_minion => $minion);
    is(
        $driver->find_element('.alert-danger span')->get_text(),
        "Unable to save needle:\nNo areas defined.",
        'areas verified via JavaScript when "Copy areas from: None" selected'
    );
    # dismiss the alert (can't use click because of fade effect)
    $driver->execute_script('$(".alert-danger").remove()');

    # select 'Copy areas from: 100%: inst-timezone-text' again
    $driver->execute_script('$("#area_select option").eq(1).prop("selected", true)');

    # specify commit message
    my $commit_message = "Example\n\nMulti\nline";
    $driver->find_element_by_id('needleeditor_commit_message')->send_keys($commit_message);

    # create new needle by clicked save button
    $driver->find_element_by_id('save')->click();
    wait_for_ajax(with_minion => $minion);

    # check state highlight appears with valid content
    is(
        $driver->find_element('#flash-messages span')->get_text(),
        'Needle test-newneedle created/updated - restart job',
        'highlight appears correct'
    );
    # check files are exists
    ok(-f "$dir/$needlename.json", "$needlename.json created");
    ok(-f "$dir/$needlename.png", "$needlename.png created");
    my $commit_args = shared_hash;
    like delete $commit_args->{message}, qr/Example.*\n.*Multi.*\n.*line/s, 'commit message matches';
    is_deeply $commit_args, {add => [qw(test-newneedle.json test-newneedle.png)]}, 'files added to commit'
      or diag explain $commit_args;

    # test overwrite needle
    add_needle_tag('test-overwritetag');
    add_workaround_property();

    like($driver->find_element_by_id('change-match')->get_attribute('class'), qr/disabled/, "match level disabled");

    # change area
    change_needle_value($xoffset, $yoffset);    # xoffset and yoffset 200 for new area
    overwrite_needle($needlename);

    # load needle editor for 'logpackages-before-package-selection', removing animation from modal again
    $driver->get('/tests/99938/modules/logpackages/steps/1/edit');
    $driver->execute_script('$(\'#modal-overwrite\').removeClass(\'fade\');');
};

subtest 'Saving needle when "taking matches" selected but no matches present' => sub {
    $driver->find_element_by_id('tag_ENV-DESKTOP-kde')->click();
    create_needle(100, 120);
    $driver->find_element_by_id('save')->click();
    check_flash_for_saving_logpackages();
};

subtest 'Saving needle when "taking matches" not selected' => sub {
    $driver->find_element_by_id('take_matches')->click();
    create_needle(200, 220);
    $driver->find_element_by_id('save')->click();
    wait_for_ajax(with_minion => $minion);
    $driver->find_element_by_id('modal-overwrite-confirm')->click();
    check_flash_for_saving_logpackages();
};

subtest 'Saving needle with only OCR areas' => sub {
    $driver->get('/tests/99938/modules/logpackages/steps/1/edit');
    $driver->execute_script('$(\'#modal-overwrite\').removeClass(\'fade\');');
    $driver->find_element_by_id('tag_ENV-DESKTOP-kde')->click();
    create_needle(200, 250);
    $driver->double_click;
    $driver->double_click;    # the match tpye change to ocr
    $driver->find_element_by_id('save')->click();
    wait_for_ajax(msg => 'wait for needle with only OCR areas created', with_minion => $minion);
    like(
        $driver->find_element('#flash-messages span')->get_text(),
        qr/Cannot create a needle with only OCR areas/,
        'error displayed for OCR-only needle'
    );
    $driver->find_element('#flash-messages .close')->click();
};

subtest 'Verify new needle\'s JSON' => sub {
    # parse new needle json
    my $new_needle_file = Mojo::File->new($dir, "$needlename.json");
    my $decoded_json = decode_json($new_needle_file->slurp);
    my $new_tags = $decoded_json->{tags};

    # check new needle json is correct
    my $match = 0;
    for my $tag (@$new_tags) {
        $match = 1 if ($tag eq 'test-overwritetag');
    }
    is($match, 1, "found new tag in new needle");
    is(
        $decoded_json->{area}[0]->{xpos},
        $decode_textarea->{area}[0]->{xpos} + $xoffset,
        "new xpos stored to new needle"
    );
    is(
        $decoded_json->{area}[0]->{ypos},
        $decode_textarea->{area}[0]->{ypos} + $yoffset,
        "new ypos stored to new needle"
    );
};

sub assert_needle_appears_in_selection {
    my ($selection_id, $needlename) = @_;

    my $selection = $driver->find_element_by_id($selection_id);
    my $new_needle_options = $driver->find_child_elements($selection, "./option[\@value='$needlename']", 'xpath');
    is(scalar @$new_needle_options, 1, "needle appears in $selection_id selection");
    is(
        OpenQA::Test::Case::trim_whitespace($new_needle_options->[0]->get_text()),
        'new: ' . $needlename,
        "needle title in $selection_id selection correct"
    );
    return $new_needle_options;
}

subtest 'New needle instantly visible after reloading needle editor' => sub {
    goto_editor_for_installer_timezone();

    is(
        $driver->find_element('#editor_warnings span')->get_text(),
        "A new needle with matching tags has been created since the job started: $needlename.json"
          . ' (tags: ENV-VIDEOMODE-text, inst-timezone, test-newtag, test-overwritetag)',
        'warning about new needle displayed'
    );

    my $based_on_option = assert_needle_appears_in_selection('tags_select', $needlename);
    my $image_option = assert_needle_appears_in_selection('image_select', $needlename);

    # uncheck 'tag_inst-timezone' tag
    $driver->find_element_by_id('tag_inst-timezone')->click();
    ok !element_prop('tag_inst-timezone', 'checked'), 'tag_inst-timezone not checked anymore';

    # check 'tag_inst-timezone' again by selecting new needle
    $based_on_option->[0]->click();
    ok element_prop('tag_inst-timezone', 'checked'), 'tag_inst-timezone checked again via new needle';
    ok element_prop('property_workaround', 'checked'), 'workaround property selected';
    is $driver->find_element_by_id('input_workaround_desc')->is_displayed, 1, 'workaround description displayed';
    is element_prop('input_workaround_desc'), 'bsc#123456 - this is a täst', 'workaround description is shown';
    # check selecting/displaying image
    my $current_image_script = 'return nEditor.bgImage.src;';
    my $current_image = $driver->execute_script($current_image_script);
    like($current_image, qr/.*installer_timezone-1\.png/, 'screenshot shown by default');
    # select image of new needle
    $image_option->[0]->click();
    wait_for_ajax(with_minion => $minion);
    $current_image = $driver->execute_script($current_image_script);
    like($current_image, qr/.*test-newneedle\.png\?.*/, 'new needle image shown');
    like($current_image, qr/.*version=13\.1.*/, 'new needle image shown');
    like($current_image, qr/.*jsonfile=.*test-newneedle\.json.*/, 'new needle image shown');
};

my @expected_needle_warnings;

subtest 'Showing new needles limited to the 5 most recent ones' => sub {
    my @expected_needle_names = ('None', '100%: inst-timezone-text',);

    # add 6 new needles (makes 7 new needles in total since one has already been added)
    my $needle_name_input = $driver->find_element_by_id('needleeditor_name');
    for (my $i = 0; $i != 7; ++$i) {
        # enter new needle name
        my $new_needle_name = "$needlename-$i";
        $needle_name_input->clear();
        $needle_name_input->send_keys($new_needle_name);
        # ensure there are areas selected (by taking over areas from previously created needle)
        $driver->execute_script('$("#area_select option").eq(1).prop("selected", true);'
              . 'if ($("#take_matches").prop("checked")) { $("#take_matches").click(); }');
        $driver->find_element_by_id('save')->click();
        wait_for_ajax(with_minion => $minion);
        # add expected warnings and needle names for needle
        if ($i >= 2) {
            unshift(@expected_needle_warnings,
                    "A new needle with matching tags has been created since the job started: $new_needle_name.json"
                  . ' (tags: ENV-VIDEOMODE-text, inst-timezone, test-newtag, test-overwritetag)');
            splice(@expected_needle_names, 2, 0, 'new: ' . $new_needle_name);
        }
    }

    $driver->get($driver->get_current_url);
    my @needle_names = map { $_->get_text() } $driver->find_elements('#tags_select option');
    is_deeply(\@needle_names, \@expected_needle_names, 'new needles limited to 5 most recent')
      or diag explain \@needle_names;
};

my $hash = '{ "name": "workaround", "value": "workaround for bsc#123456" }';
my %tests = (string => '"workaround"', hash => $hash);
foreach my $type (sort keys %tests) {
    subtest "Needle with $type properties" => sub {
        $needle_json_file->spurt(qq({ "properties": [ $tests{$type} ] }));
        $driver->refresh;
        $driver->title_is('openQA: Needle Editor', 'needle editor shows up');
        ok element_prop('property_workaround', 'checked'), 'workaround property selected';
        ok $driver->find_element_by_id('input_workaround_desc')->is_displayed, 'workaround description displayed';
    };
}

subtest 'Broken needle is handled gracefully' => sub {
    $needle_json_file->spurt("{{{,};");
    $driver->refresh;
    $driver->title_is('openQA: Needle Editor', 'needle editor still shows up');
    my @warnings = (split /\n/, $driver->find_element('#editor_warnings span')->get_text());
    like(
        $warnings[0],
        qr/Could not parse needle inst-timezone-text for opensuse 13\.1: .+ at character offset/,
        'warning about broken needle displayed'
    ) or diag explain \@warnings;
};

subtest 'Deletion of needle is handled gracefully' => sub {
    $needle_json_file->remove;
    $driver->refresh;
    $driver->title_is('openQA: Needle Editor', 'needle editor still shows up');
    my @warnings = (split /\n/, $driver->find_element('#editor_warnings span')->get_text());
    is(
        $warnings[0],
        'Could not parse needle inst-timezone-text for opensuse 13.1: File not found',
        'warning about missing needle displayed'
    ) or diag explain \@warnings;
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

subtest 'show needle editor for screenshot (without any tags)' => sub {
    $driver->get_ok('/tests/99946');
    wait_for_ajax(with_minion => $minion);
    $driver->find_element_by_xpath('//a[@href="#step/isosize/1"]')->click();
    wait_for_ajax(with_minion => $minion);
    $driver->find_element('.step_actions .create_new_needle')->click();
    wait_for_ajax(with_minion => $minion);
    is(OpenQA::Test::Case::trim_whitespace($driver->find_element_by_id('image_select')->get_text()),
        'Screenshot', 'images taken from screenshot');
};

subtest 'open needle editor for running test' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->ua->max_redirects(1);
    warnings { $t->get_ok('/tests/99980/edit') };
    note(   'ignoring warning "DateTime objects passed to search() are not supported properly"'
          . ' at lib/OpenQA/WebAPI/Controller/Step.pm line 211');
    $t->status_is(200);
    $t->text_is(title => 'openQA: Needle Editor', 'needle editor shown for running test');
    is(
        $t->tx->req->url->path->to_string,
        '/tests/99980/modules/installation_mode/steps/2/edit',
        'redirected to correct module/step'
    );
};

subtest 'error handling when opening needle editor for running test' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');

    subtest 'no worker assigned' => sub {
        $t->get_ok('/tests/99946/edit')->status_is(404);
        $t->text_is(title => 'openQA: Needle Editor', 'title still the same');
        $t->text_like(
            '#content p',
qr/The test opensuse-13\.1-DVD-i586-Build0091-textmode\@32bit has no worker assigned so the page \"Needle Editor\" is not available\./,
            'error message'
        );

        # test error handling for other 'Running.pm' routes as well
        $t->get_ok('/tests/99946/livelog')->status_is(404);
        $t->text_is(title => 'openQA: Page not found', 'generic title present');
        $t->text_like(
            '#content p',
qr/The test opensuse-13\.1-DVD-i586-Build0091-textmode\@32bit has no worker assigned so this route is not available\./,
            'error message'
        );
    };

    subtest 'no running module' => sub {
        $t->get_ok('/tests/99963/edit')->status_is(404);
        $t->text_like(
            '#content p',
qr/The test has no currently running module so opening the needle editor is not possible\. Likely results have not been uploaded yet so reloading the page might help\./,
            'error message'
        );
    };
};

kill_driver();

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
          ->status_is(403, 'access to files outside the test directory not granted (absolute)');
    };
    map { like($_, qr/is not in a subdir of/, 'expected warning') } @warnings;
    @warnings = warnings {
        $t->get_ok(
'/needles/opensuse/test-newneedle.png?jsonfile=t/data/openqa/share/tests/opensuse/needles/../../../../try/to/break_out.json'
        )->status_is(403, 'access to files outside the test directory not granted (relative)');
    };
    map { like($_, qr/cannot contain ../, 'expected warning') } @warnings;

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

$fake_worker->unregister;

done_testing();
