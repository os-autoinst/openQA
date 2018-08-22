#! /usr/bin/perl

# Copyright (C) 2018 SUSE LLC
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

# note: Tests the only the UI-layer of the developer mode. So no
#       web socket connection to the live view handler is established here.
#       Instead, the state is injected via JavaScript commands.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Module::Load::Conditional qw(can_load);
use Mojo::Base -strict;
use Mojo::File qw(path tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data;

sub schema_hook {
    my $schema             = OpenQA::Test::Database->new->create;
    my $workers            = $schema->resultset('Workers');
    my $jobs               = $schema->resultset('Jobs');
    my $developer_sessions = $schema->resultset('DeveloperSessions');

    # assign a worker to job 99961
    my $job_id = 99961;
    my $worker = $workers->find({job_id => $job_id});
    $jobs->find($job_id)->update({assigned_worker_id => $worker->id});

    # set required worker properties
    $worker->set_property(WORKER_TMPDIR => path(tempdir, 't', 'devel-mode-ui.d'));
    $worker->set_property(CMD_SRV_URL => 'http://remotehost:20013/token99964');

    # add developer session for a finished job
    $developer_sessions->register(99926, 99901);
}

my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# sets the properties of the specified global JavaScript object and updates the developer panel
sub fake_state {
    my ($variable, $state) = @_;

    my $java_script = '';
    $java_script .= "$variable\['$_'\] = $state->{$_};" for (keys %$state);
    $java_script .= 'updateDeveloperPanel();';

    print("injecting JavaScript: $java_script\n");
    $driver->execute_script($java_script);
}

# checks whether the commands sent by the JavaScript since the last call matches the expected commands
sub assert_sent_commands {
    my ($expected, $test_name) = @_;

    my $sent_cmds
      = $driver->execute_script('var sentCmds = window.sentCmds; window.sentCmds = undefined; return sentCmds;');
    is_deeply($sent_cmds, $expected, $test_name);
}

# checks whether the flash messages of the specified kind are present
sub assert_flash_messages {
    my ($kind, $expected_messages, $test_name) = @_;
    my $kind_selector = $kind eq 'any' ? 'alert' : '.alert-' . $kind;

    my @flash_messages = $driver->find_elements("#flash-messages $kind_selector > span");
    is(
        scalar @flash_messages,
        scalar @$expected_messages,
        "correct number of $kind flash messages present ($test_name)"
    );

    my $index = 0;
    for my $expected_message (@$expected_messages) {
        like($flash_messages[$index]->get_text(), $expected_message, $test_name,) if ($expected_message);
        $index += 1;
    }
}

# clicks on the header of the developer panel
sub click_header {
    $driver->find_element('#developer-panel .card-header')->click();
}

# login an navigate to a running job with assigned worker
$driver->get('/login');

# navigate to a finished test
$driver->get('/tests/99926');
like(
    $driver->find_element('#info_box .card-body')->get_text(),
    qr/Developer session was opened during testrun by artie/,
    'responsible developer shown for finished test'
);

# navigate to live view of running test
$driver->get('/tests/99961#live');

# mock some JavaScript functions
mock_js_functions(
    updateStatus             => '',
    setupWebsocketConnection => '',
    startDeveloperSession =>
'developerMode.ownSession = true; developerMode.useDeveloperWsRoute = true; handleWebsocketConnectionOpened(developerMode.wsConnection);',
    sendWsCommand => 'if (!window.sentCmds) { window.sentCmds = [] } window.sentCmds.push(arg1);',
);

# fake module list (since we're not executing a real test here)
$driver->execute_script(
'$("#developer-pause-at-module").append("<optgroup label=\"installation\"><option>boot</option><option>welcome</option><option>foo</option><option>bar</option></optgroup>")'
);

subtest 'devel UI hidden when running, but modules not initialized' => sub {
    my $info_panel = $driver->find_element('#info_box .card-body');
    my $info_text  = $info_panel->get_text();
    like($info_text, qr/State\: running.*\nAssigned worker\: remotehost\:1/, 'job is running');
    element_hidden('#developer-instructions');
    element_hidden('#developer-panel');
};

subtest 'devel UI shown when running module known' => sub {
    fake_state(testStatus => {running => '"welcome"'});
    element_hidden('#developer-instructions');
    element_visible('#developer-panel');
    element_visible(
        '#developer-panel .card-header',
        qr/Developer mode.*\nretrieving status.*\nregular test execution - click to expand/,
    );
    element_hidden('#developer-panel .card-body');

    # expand
    click_header();
    element_visible('#developer-panel .card-body', qr/establishing connection/, qr/Pause at module/);

    # collapse again
    click_header();
    element_hidden('#developer-panel .card-body');
};

subtest 'state shown when connected' => sub {
    # running, current module unknown
    fake_state(
        developerMode => {
            isConnected    => 'true',
            pauseAtTimeout => 'false',
        });
    element_hidden('#developer-instructions');
    element_visible('#developer-panel');
    element_visible(
        '#developer-panel .card-header',
        qr/Developer mode.*\nrunning.*\nregular test execution - click to expand/,
        [qr/paused/, qr/owned by/],
    );
    element_hidden('#developer-panel .card-body');

    # running, current module known
    fake_state(developerMode => {currentModule => '"installation-welcome"'});
    element_hidden('#developer-instructions');
    element_visible('#developer-panel .card-header', qr/current module: installation-welcome/, qr/paused/,);
    my @options   = $driver->find_elements('#developer-pause-at-module option');
    my @optgroups = $driver->find_elements('#developer-pause-at-module optgroup');
    is(
        $_->get_css_attribute('display'),
        (($_->get_value() // '') =~ qr/boot|welcome/) ? 'none' : 'block',
        'only modules after the current module displayed'
    ) for (@options, @optgroups);

    # will pause at certain module
    fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
    element_hidden('#developer-instructions');
    element_visible('#developer-panel .card-header', qr/will pause at module: installation-foo/, qr/paused/,);
    is(scalar @options, 5, '5 options in module to pause at selection present');
    is($_->is_selected(), $_->get_value() eq 'foo' ? 1 : 0, 'only foo selected') for (@options);

    # has already completed the module to pause at
    fake_state(developerMode => {moduleToPauseAt => '"installation-boot"'});
    element_hidden('#developer-instructions');
    element_visible('#developer-panel .card-header', qr/current module: installation-welcome/, qr/paused/,);
    is($_->is_selected(), $_->get_value() eq 'boot' ? 1 : 0, 'only boot selected') for (@options);

    # currently paused
    fake_state(developerMode => {isPaused => '"some reason"'});
    element_visible('#developer-instructions',
        qr/System is waiting for developer, connect to remotehost at port 91 with Shared mode/,
    );
    element_visible('#developer-panel .card-header', qr/paused at module: installation-welcome/, qr/current module/,);
    element_visible('#developer-pause-reason', qr/reason: some reason/);

    # developer session opened
    fake_state(
        developerMode => {
            develSessionDeveloper => '"some developer"',
            develSessionStartedAt => '"2018-06-22 12:00:00 +0000"',
            develSessionTabCount  => '42',
        });
    element_visible(
        '#developer-panel .card-header',
        qr/owned by some developer \(.* ago, developer has 42 tabs open\)/,
        qr/regular test execution - click to expand/,
    );
};

# revert state changes from previous tests
fake_state(
    developerMode => {
        ownSession            => 'false',
        moduleToPauseAt       => 'undefined',
        isPaused              => 'false',
        develSessionDeveloper => 'undefined',
        develSessionStartedAt => 'undefined',
        develSessionTabCount  => 'undefined',
    });

my @expected_text_on_initial_session_creation = (qr/and confirm to apply/, qr/Confirm to control this test/,);
my @expected_text_after_session_created       = (qr/the controls below\./, qr/Cancel job/,);

subtest 'expand developer panel' => sub {
    click_header();
    element_visible(
        '#developer-panel .card-body',
        \@expected_text_on_initial_session_creation,
        [@expected_text_after_session_created, qr/Resume/],
    );
    element_visible('#developer-pause-at-module');

    subtest 'behavior when changes have not been confirmed' => sub {
        my @options = $driver->find_elements('#developer-pause-at-module option');

        $options[4]->set_selected();
        assert_sent_commands(undef, 'changes not instantly submitted');

        subtest 'module to pause at not updated' => sub {
            fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
            is($_->is_selected(), $_->get_value() eq 'bar' ? 1 : 0, 'still only bar selected') for (@options);
        };
    };
};

subtest 'collapse developer panel' => sub {
    click_header();
    element_hidden('#developer-panel .card-body');
};

subtest 'start developer session' => sub {
    # expand panel again
    click_header();

    $driver->find_element('Confirm to control this test', 'link_text')->click();
    element_visible(
        '#developer-panel .card-body',
        \@expected_text_after_session_created,
        [@expected_text_on_initial_session_creation, qr/Resume/],
    );
    assert_sent_commands(
        [
            {
                cmd  => 'set_pause_at_test',
                name => 'installation-bar',
            }
        ],
        'changes from subtest "expand developer panel" submitted'
    );

    subtest 'resume paused test' => sub {
        fake_state(developerMode => {isPaused => '"some reason"'});
        $driver->find_element('Resume test execution', 'link_text')->click();
        assert_sent_commands([{cmd => 'resume_test_execution'}], 'command for resuming test execution sent');
    };

    subtest 'select module to pause at' => sub {
        my @options = $driver->find_elements('#developer-pause-at-module option');
        fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
        is($_->is_selected(), $_->get_value() eq 'foo' ? 1 : 0, 'foo selected') for (@options);

        $options[3]->set_selected();    # select installation-foo
        assert_sent_commands(undef, 'no command sent if nothing changes');

        $options[4]->set_selected();    # select installation-bar
        assert_sent_commands(
            [
                {
                    cmd  => 'set_pause_at_test',
                    name => 'installation-bar',
                }
            ],
            'command to set module to pause at sent'
        );

        $options[0]->set_selected();    # select <don't pause>
        assert_sent_commands(
            [
                {
                    cmd  => 'set_pause_at_test',
                    name => undef,
                }
            ],
            'command to clear module to pause at sent'
        );
    };

    subtest 'select whether to pause on assert_screen failure' => sub {
        my $checkbox = $driver->find_element('#developer-pause-on-timeout');
        is($checkbox->is_selected, 0, 'check box initially not selected');

        # turn pausing on assert_screen on
        $checkbox->click();
        assert_sent_commands(
            [
                {
                    cmd  => 'set_pause_on_assert_screen_timeout',
                    flag => 1,
                }
            ],
            'command to pause on assert_screen failure sent'
        );

        # fake the feedback from os-autoinst
        fake_state(developerMode => {pauseAtTimeout => 1});

        # turn pausing on assert_screen off
        $checkbox->click();
        assert_sent_commands(
            [
                {
                    cmd  => 'set_pause_on_assert_screen_timeout',
                    flag => 0,
                }
            ],
            'command to unset pause on assert_screen failure sent'
        );
    };

    subtest 'quit session' => sub {
        $driver->find_element('Cancel job', 'link_text')->click();
        assert_sent_commands([{cmd => 'quit_development_session'}], 'command for quitting session sent');
        element_hidden('#developer-panel .card-body');
    };
};

subtest 'process state changes from os-autoinst' => sub {
    fake_state(
        developerMode => {
            currentModule   => '"installation-welcome"',
            isPaused        => '"some reason"',
            moduleToPauseAt => 'undefined',
        });

    # in contrast to the other subtests (which just fake the state via fake_state helper) this subtest will
    # actually test processing of commands received via the websocket connection

    subtest 'message not from current connection ignored' => sub {
        $driver->execute_script(
'handleMessageVisWebsocketConnection("foo", { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_test_full_name\":\"some test\",\"paused\":true}}" });'
        );
        element_visible(
            '#developer-panel .card-header',
            qr/paused at module: installation-welcome/,
            qr/current module/,
        );
    };

    subtest 'testname and paused state updated' => sub {
        $driver->execute_script(
'handleMessageVisWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"resume_test_execution\":\"foo\"}}" });'
        );
        element_visible(
            '#developer-panel .card-header',
            qr/current module: installation-welcome/,
            qr/paused at module/,
        );

        $driver->execute_script(
'handleMessageVisWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_test_full_name\":\"some test\",\"paused\":true, \"set_pause_on_assert_screen_timeout\": 1}}" });'
        );
        element_visible('#developer-panel .card-header', qr/paused at module: some test/, qr/current module/,);
        is(
            $driver->find_element('#developer-pause-on-timeout')->is_selected,
            1, 'check box for pause on assert_screen timeout updated',
        );
    };

    subtest 'error handling, flash messages' => sub {
        $driver->execute_script(
            'handleMessageVisWebsocketConnection("foo", { data: "{\"type\":\"error\",\"what\":\"some error\"}" });');
        assert_flash_messages(any => [], 'messsages not from current connection ignored');

        $driver->execute_script('handleMessageVisWebsocketConnection(developerMode.wsConnection, { });');
        assert_flash_messages(any => [], 'messages with no data are ignored');

        my $handle_error
          = 'handleMessageVisWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"error\",\"what\":\"some error\"}" });';
        my $handle_another_error
          = 'handleMessageVisWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"error\",\"what\":\"another error\"}" });';
        $driver->execute_script(
            'handleMessageVisWebsocketConnection(developerMode.wsConnection, { data: "invalid { json" });');
        $driver->execute_script($handle_error);
        $driver->execute_script($handle_error);
        $driver->execute_script($handle_another_error);
        assert_flash_messages(
            danger => [qr/Unable to parse/, qr/some error/, qr/another error/],
            'errors shown via flash messages, same error not shown twice'
        );

        subtest 'dismissed message appears again' => sub {
            # click "X" button of 2nd flash message
            $driver->execute_script('$(".alert-danger").removeClass("fade")');    # prevent delay due to animation
            $driver->execute_script('return $($(".alert-danger")[1]).find("button").click();');

            assert_flash_messages(
                danger => [qr/Unable to parse/, qr/another error/],
                'flash message "some error" dismissed'
            );
            $driver->execute_script($handle_error);
            assert_flash_messages(
                danger => [qr/Unable to parse/, qr/another error/, qr/some error/],
                'unique flash message appears again after dismissed'
            );
        };
    };
};

kill_driver();
done_testing();
