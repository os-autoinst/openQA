#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# note: Tests the only the UI-layer of the developer mode. So no
#       web socket connection to the live view handler is established here.
#       Instead, the state is injected via JavaScript commands.

use Test::Most;

use Mojo::Base -signatures;
use Module::Load::Conditional qw(can_load);
use Mojo::File qw(path tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Test::TimeLimit '30';
use OpenQA::WebSockets::Client;
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

sub prepare_database {
    my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
    my $workers = $schema->resultset('Workers');
    my $jobs = $schema->resultset('Jobs');
    my $developer_sessions = $schema->resultset('DeveloperSessions');

    # make OpenQA::WebSockets::Client::send_msg() a noop (tested in ../34-developer_mode-unit.t anyways)
    my $ipc_mock_module = Test::MockModule->new('OpenQA::WebSockets::Client');
    $ipc_mock_module->redefine(send_msg => sub { });

    # assign a worker to job 99961
    my $job_id = 99961;
    my $worker = $workers->find({job_id => $job_id}) or die "worker for job '$job_id' not found";
    $jobs->find($job_id)->update({assigned_worker_id => $worker->id});

    # set required worker properties
    $worker->set_property(WORKER_TMPDIR => tempdir->child('t', 'devel-mode-ui.d'));
    $worker->set_property(CMD_SRV_URL => 'http://remotehost:20013/token99964');

    # add developer session for a finished job
    $workers->create(
        {
            job_id => 99926,
            host => 'bar',
            instance => 42,
        });
    $developer_sessions->register(99926, 99901)
      or note 'unable to register developer session for finished job';
}

prepare_database;

my $t = Test::Mojo->new('OpenQA::WebAPI');
driver_missing unless my $driver = call_driver;

# executes JavaScript code taking a note
sub inject_java_script {
    my ($java_script) = @_;

    note("injecting JavaScript: $java_script\n");
    $driver->execute_script($java_script);
}

# sets the properties of the specified global JavaScript object and updates the developer panel
sub fake_state {
    my ($variable, $state) = @_;

    my $java_script = '';
    $java_script .= "$variable\['$_'\] = $state->{$_};" for (keys %$state);
    $java_script .= 'updateDeveloperPanel();';
    inject_java_script($java_script);
}

# invokes the handler for messages from ws connection
sub fake_message_from_ws_connection {
    my ($message) = @_;

    inject_java_script("handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: \"$message\" });");
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

    my @flash_messages = $driver->find_elements("#developer-flash-messages $kind_selector > span");
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

sub js_variable {
    my ($variable_name) = @_;
    return $driver->execute_script("return $variable_name;");
}

# clicks on the header of the developer panel
sub click_header {
    $driver->find_element('#developer-status')->click();
}

sub options_state { map_elements('#developer-pause-at-module option', 'e.selected, e.value || ""') }

# login an navigate to a running job with assigned worker
$driver->get('/login');

# navigate to a finished test
$driver->get('/tests/99926?status_updates=0');
like(
    $driver->find_element('#info_box .card-body')->get_text(),
    qr/Developer session was opened during testrun by artie/,
    'responsible developer shown for finished test'
);

# navigate to live view of running test
$driver->get('/tests/99961?status_updates=0#live');
wait_for_ajax(msg => 'live tab of job 99961 loaded');

# mock some JavaScript functions
mock_js_functions(
    updateStatus => '',
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
    my $info_text = $info_panel->get_text();
    like($info_text, qr/State\: running.*Assigned worker\: remotehost\:1/s, 'job is running');
    element_hidden('#developer-global-session-info');
    element_hidden('#developer-vnc-notice');
    element_hidden('#developer-panel');
};

subtest 'devel UI shown when running module known' => sub {
    fake_state(testStatus => {running => '"welcome"'});

    element_hidden('#developer-global-session-info');
    element_hidden('#developer-vnc-notice');
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
            isConnected => 'true',
            pauseAtTimeout => 'false',
        });
    element_hidden('#developer-global-session-info');
    element_hidden('#developer-vnc-notice');
    element_visible('#developer-panel');
    element_visible(
        '#developer-panel .card-header',
        qr/Developer mode.*\nrunning.*\nregular test execution - click to expand/,
        [qr/paused/, qr/owned by/],
    );
    element_hidden('#developer-panel .card-body');

    # running, current module known
    fake_state(developerMode => {currentModule => '"installation-welcome"'});
    element_hidden('#developer-vnc-notice');
    element_visible('#developer-panel .card-header', qr/current module: installation-welcome/, qr/paused/,);

    my $options_state = map_elements('#developer-pause-at-module option, #developer-pause-at-module optgroup',
        'e.style.display, e.value || ""');
    subtest 'only modules after the current module displayed' => sub {
        is $_->[0], ($_->[1] =~ qr/boot|welcome/) ? 'none' : '', "option $_->[1]" for @$options_state;
    } or diag explain $options_state;

    # will pause at certain module
    fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
    element_hidden('#developer-vnc-notice');
    element_visible('#developer-panel .card-header', qr/will pause at module: installation-foo/, qr/paused/,);
    $options_state = options_state;
    subtest 'only foo selected' => sub {
        is scalar @$options_state, 5, '5 options in module to pause at selection present';
        is $_->[0], $_->[1] eq 'foo' ? 1 : 0, "option $_->[1]" for @$options_state;
    } or diag explain $options_state;

    # has already completed the module to pause at
    fake_state(developerMode => {moduleToPauseAt => '"installation-boot"'});
    element_hidden('#developer-vnc-notice');
    element_visible('#developer-panel .card-header', qr/current module: installation-welcome/, qr/paused/,);
    $options_state = options_state;
    subtest 'only boot selected' => sub {
        is $_->[0], $_->[1] eq 'boot' ? 1 : 0, "option $_->[1]" for @$options_state;
    } or diag explain $options_state;

    # currently paused
    fake_state(developerMode => {isPaused => '"some reason"'});
    element_visible(
        '#developer-vnc-notice',
qr/You might be able to connect to the SUT at remotehost:5991 via VNC with shared mode enabled \(eg\. vncviewer remotehost:5991 -Shared for TigerVNC\)\./,
    );
    element_visible(
        '#developer-panel .card-header',
        qr/paused at module: installation-welcome/,
        [qr/current module/, qr/uploading/],
    );
    element_visible('#developer-status-appendix', qr/reason: some reason/);

    # developer session opened
    fake_state(
        developerMode => {
            develSessionDeveloper => '"some developer"',
            develSessionStartedAt => '"2018-06-22 12:00:00 +0000"',
            develSessionTabCount => '42',
        });
    element_visible('#developer-global-session-info', qr/Developer session has been opened by some developer/,);
    element_visible(
        '#developer-panel .card-header',
        qr/owned by some developer \(.* ago, developer has 42 tabs open\)/,
        qr/regular test execution - click to expand/,
    );
};

subtest 'configuration issue shown' => sub {
    fake_state(developerMode => {badConfiguration => 'true'});

    element_visible(
        '#developer-panel .card-header',
        qr/configuration issue/,
        [qr/retrieving/, qr/current module/, qr/uploading/],
    );
    click_header();
    element_visible('#developer-config-issue-note', qr/steps to debug developer mode setup/);
};

subtest 'stopping shown' => sub {
    fake_state(developerMode => {stoppingTestExecution => 'true'});

    element_visible(
        '#developer-panel .card-header',
        qr/stopping/, [qr/retrieving/, qr/current module/, qr/uploading/, qr/configuration issue/],
    );
    element_visible('#developer-stopping-note', qr/test is about to stop/);
};

# revert state changes from previous tests
click_header();
fake_state(
    developerMode => {
        ownSession => 'false',
        moduleToPauseAt => 'undefined',
        isPaused => 'false',
        develSessionDeveloper => 'undefined',
        develSessionStartedAt => 'undefined',
        develSessionTabCount => 'undefined',
        badConfiguration => 'false',
        stoppingTestExecution => 'false',
    });

my @expected_text_on_initial_session_creation = (qr/and confirm to apply/, qr/Confirm to control this test/);
my @expected_text_after_session_created = (qr/the controls below\./);

subtest 'expand developer panel' => sub {
    click_header();
    element_visible(
        '#developer-panel .card-body',
        \@expected_text_on_initial_session_creation,
        [@expected_text_after_session_created, qr/Resume/],
    );
    element_visible('#developer-pause-at-module');
    element_hidden('#developer-stopping-note');
    element_hidden('#developer-config-issue-note');

    subtest 'behavior when changes have not been confirmed' => sub {
        my @options = $driver->find_elements('#developer-pause-at-module option');

        ok $options[4], 'option #5 present' or return undef;
        $options[4]->click();
        assert_sent_commands(undef, 'changes not instantly submitted');

        fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
        my $options_state = options_state;
        subtest 'still only bar selected' => sub {
            is $_->[0], $_->[1] eq 'bar' ? 1 : 0, "option $_->[1]" for @$options_state;
        } or diag explain $options_state;
    };

    my $popover_icon = $driver->find_element('#developer-form .help_popover');
    if (ok $popover_icon, 'popover icon(s) present') {
        $popover_icon->click;
        ok $driver->find_element('body > .popover'), 'popover shown';
    }
};

subtest 'collapse developer panel' => sub {
    click_header();
    element_hidden('#developer-panel .card-body');

    subtest 'panel stays collapsed if test is paused and it is the own session when collapsed manually' => sub {
        fake_state(
            developerMode => {
                ownSession => 'true',
                isPaused => 'true',
            });
        element_hidden('#developer-panel .card-body');
    };
};

subtest 'panel is automatically expanded if test is paused and it is the own session' => sub {
    fake_state(
        developerMode => {
            panelExplicitelyCollapsed => 'false',
        });
    element_visible('#developer-panel .card-body');
};

subtest 'revert state changes from previous subtests (not supposed to collapse the panel)' => sub {
    fake_state(
        developerMode => {
            ownSession => 'false',
            isPaused => 'false',
        });
    element_visible('#developer-panel .card-body');
    element_hidden('#developer-config-issue-note');
};

subtest 'start developer session' => sub {
    assert_sent_commands(undef, 'no changes submitted so far');

    # select to pause at 'installation-bar'
    my @options = $driver->find_elements('#developer-pause-at-module option');
    ok $options[4], 'option #5 present' or return undef;
    $options[4]->click();

    # start developer session by submitting the changes
    $driver->find_element('Confirm to control this test', 'link_text')->click();
    element_visible(
        '#developer-panel .card-body',
        \@expected_text_after_session_created,
        [@expected_text_on_initial_session_creation, qr/Skip timeout/, qr/Resume/],
    );
    assert_sent_commands(
        [
            {
                cmd => 'set_pause_at_test',
                name => 'installation-bar',
            }
        ],
        'changes submitted'
    );

    subtest 'skipping timeout' => sub {
        fake_state(developerMode => {currentApiFunction => '"assert_screen"'});
        element_visible(
            '#developer-panel .card-body',
            [@expected_text_after_session_created, qr/Skip timeout/],
            [@expected_text_on_initial_session_creation, qr/Resume/],
        );
        $driver->find_element('Skip timeout', 'link_text')->click();
        assert_sent_commands(
            [
                {
                    cmd => 'set_assert_screen_timeout',
                    timeout => 0,
                }
            ],
            'timeout set to zero'
        );
    };

    # assume we're paused for the next subtests
    fake_state(developerMode => {isPaused => '"some reason"'});

    subtest 'opening needle editor not proposed when not ready' => sub {
        # the worker isn't uploading up to the current module so 'Open needle editor' should not be shown
        # besides, skipping the timeout should no longer be offered because we're paused now
        element_visible('#developer-panel .card-body', qr/Resume/, [qr/Open needle editor/, qr/Skip timeout/]);

        # uploading current module in progress
        fake_state(
            developerMode => {
                uploadingUpToCurrentModule => 'true',
                outstandingImagesToUpload => '1',
                outstandingFilesToUpload => '0',
            });
        element_visible(
            '#developer-panel .card-header',
            qr/paused at module: installation-welcome, uploading/,
            qr/current module/,
        );
        element_visible('#developer-panel .card-body', qr/Resume/, qr/Open needle editor/);
    };

    subtest 'opening needle editor proposed when current module has been uploaded' => sub {
        fake_state(
            developerMode => {
                outstandingImagesToUpload => '0',
            });
        element_visible('#developer-panel .card-header', qr/paused at module: installation-welcome/, qr/uploading/,);
        element_visible('#developer-panel .card-body', [qr/Resume/, qr/Open needle editor/]);
    };

    subtest 'resume paused test' => sub {
        $driver->find_element('Resume test execution', 'link_text')->click();
        assert_sent_commands([{cmd => 'resume_test_execution'}], 'command for resuming test execution sent');
    };

    subtest 'select module to pause at' => sub {
        fake_state(developerMode => {moduleToPauseAt => '"installation-foo"'});
        my $options_state = options_state;
        subtest 'only foo selected' => sub {
            is $_->[0], $_->[1] eq 'foo' ? 1 : 0, "option $_->[1]" for @$options_state;
        } or diag explain $options_state;

        ok $options[3], 'option #4 present' or return undef;
        $options[3]->click();    # select installation-foo
        assert_sent_commands(undef, 'no command sent if nothing changes');

        ok $options[4], 'option #5 present' or return undef;
        $options[4]->click();    # select installation-bar
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_at_test',
                    name => 'installation-bar',
                }
            ],
            'command to set module to pause at sent'
        );

        $options[0]->click();    # select <don't pause>
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_at_test',
                    name => undef,
                }
            ],
            'command to clear module to pause at sent'
        );
    };

    subtest 'select whether to pause on assert_screen failure' => sub {
        my @options = $driver->find_elements('#developer-pause-on-mismatch option');
        my $options_state = map_elements('#developer-pause-on-mismatch option', 'e.selected');
        is scalar @options, 3, 'three options for pausing on screen mismatch';
        is $options_state->[0]->[0], 1, 'pausing on screen mismatch disabled by default';

        # attempt to turn pausing on assert_screen on when current state unknown
        $options[1]->click();
        assert_sent_commands(undef, 'prevent overriding pause on mismatch with form defaults if unknown');

        # assume we know the pausing on screen match is disabled
        fake_state(developerMode => {pauseOnScreenMismatch => 'false'});
        $options_state = map_elements('#developer-pause-on-mismatch option', 'e.selected');
        is $options_state->[0]->[0], 1, 'pausing on screen mismatch still disabled';

        # turn pausing on assert_screen on
        $options[1]->click();
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_on_screen_mismatch',
                    pause_on => 'assert_screen',
                }
            ],
            'command to pause on assert_screen failure sent'
        );

        # fake the feedback from os-autoinst
        fake_state(developerMode => {pauseOnScreenMismatch => '"assert_screen"'});
        $options_state = map_elements('#developer-pause-on-mismatch option', 'e.selected');
        is $options_state->[1]->[0], 1, 'still right option selected';

        # turn pausing on check_screen on
        $options[2]->click();
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_on_screen_mismatch',
                    pause_on => 'check_screen',
                }
            ],
            'command to pause on check_screen failure sent'
        );

        # fake the feedback from os-autoinst
        fake_state(developerMode => {pauseOnScreenMismatch => '"check_screen"'});
        $options_state = map_elements('#developer-pause-on-mismatch option', 'e.selected');
        is $options_state->[2]->[0], 1, 'still right option selected (2)';

        # turn pausing on screen mismatch off
        $options[0]->click();
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_on_screen_mismatch',
                    pause_on => undef,
                }
            ],
            'command to turn pausing on screen mismatch off sent'
        );
    };

    subtest 'select whether to pause on next command' => sub {
        ok !element_prop('developer-pause-on-next-command', 'checked'), 'checkbox not checked yet';

        my $checkbox = $driver->find_element_by_id('developer-pause-on-next-command');
        $checkbox->click();
        assert_sent_commands(undef, 'nothing happens unless the current state is known');

        fake_state(developerMode => {pauseOnNextCommand => '0'});

        $checkbox->click();
        assert_sent_commands(
            [
                {
                    cmd => 'set_pause_on_next_command',
                    flag => 1,
                }
            ],
            'command to pause on next command sent'
        );

        # fake feedback from os-autoinst
        fake_state(developerMode => {pauseOnNextCommand => '1'});
        ok element_prop('developer-pause-on-next-command', 'checked'), 'pause on next command is checked now';

        # test command processing
        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"pause_on_next_command\":0}}" });'
        );
        is js_variable('developerMode.pauseOnNextCommand'), 0, 'pauseOnNextCommand unset again';
        ok !element_prop('developer-pause-on-next-command', 'checked'), 'pause on next command is disabled again';
    };

    subtest 'quit session' => sub {
        $driver->execute_script('quitDeveloperSession();');
        assert_sent_commands([{cmd => 'quit_development_session'}], 'command for quitting session sent');
        element_hidden('#developer-panel .card-body');
    };
};

subtest 'process state changes from os-autoinst/worker' => sub {
    fake_state(
        developerMode => {
            currentModule => '"installation-welcome"',
            isPaused => '"some reason"',
            moduleToPauseAt => 'undefined',
            currentApiFunction => 'undefined',
        });

    # in contrast to the other subtests (which just fake the state via fake_state helper) this subtest will
    # actually test processing of commands received via the websocket connection

    subtest 'message not from current connection ignored' => sub {
        $driver->execute_script(
'handleMessageFromWebsocketConnection("foo", { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_test_full_name\":\"some test\",\"paused\":true}}" });'
        );
        element_visible(
            '#developer-panel .card-header',
            qr/paused at module: installation-welcome/,
            qr/current module/,
        );
    };

    subtest 'testname and paused state updated' => sub {
        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"resume_test_execution\":\"foo\"}}" });'
        );
        element_visible(
            '#developer-panel .card-header',
            qr/current module: installation-welcome/,
            qr/paused at module/,
        );

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_test_full_name\":\"some test\",\"paused\":true, \"set_pause_on_screen_mismatch\":\"assert_screen\"}}" });'
        );
        element_visible('#developer-panel .card-header', qr/paused at module: some test/, qr/current module/);
        my $options_state = map_elements('#developer-pause-on-mismatch option', 'e.selected');
        ok $options_state->[1]->[0], 'selection for pausing on screen mismatch updated' or diag explain $options_state;
    };

    subtest 'upload progress handled' => sub {
        is(js_variable('developerMode.detailsForCurrentModuleUploaded'),
            0, 'details for current module initially not considered uploaded');

        fake_state(
            developerMode => {
                uploadingUpToCurrentModule => 'false',
                outstandingImagesToUpload => '0',
                outstandingFilesToUpload => '0',
            });

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"upload progress\",\"data\":{\"outstanding_images\":5,\"outstanding_files\":7,\"upload_up_to_current_module\":true}}" });'
        );

        is(js_variable('developerMode.outstandingImagesToUpload'), 5, 'outstanding images updated');
        is(js_variable('developerMode.outstandingFilesToUpload'), 7, 'outstanding files updated');
        is(js_variable('developerMode.uploadingUpToCurrentModule'), 1, 'uploading up to current module updated');
        is(js_variable('developerMode.detailsForCurrentModuleUploaded'),
            0, 'details for current module still not considered uploaded');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"upload progress\",\"data\":{\"outstanding_files\":0}}" });'
        );
        is(js_variable('developerMode.outstandingImagesToUpload'), 5, 'outstanding images not changed');
        is(js_variable('developerMode.outstandingFilesToUpload'), 0, 'outstanding files updated');
        is(js_variable('developerMode.detailsForCurrentModuleUploaded'),
            0, 'details for current module still not considered uploaded');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"upload progress\",\"data\":{\"outstanding_images\":0,\"outstanding_files\":0,\"upload_up_to_current_module\":true}}" });'
        );
        is(js_variable('developerMode.outstandingImagesToUpload'), 0, 'outstanding images updated');
        is(js_variable('developerMode.outstandingFilesToUpload'), 0, 'outstanding files has bot changed');
        is(js_variable('developerMode.detailsForCurrentModuleUploaded'),
            1, 'details for current module considered uploaded');
    };

    subtest 'curent API function handled' => sub {
        is(js_variable('developerMode.currentApiFunction'), undef, 'current API function not set so far');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_api_function\":\"assert_screen\"}}" });'
        );
        is(js_variable('developerMode.currentApiFunction'), 'assert_screen', 'current API function set');
        is(js_variable('developerMode.currentApiFunctionArgs'), '', 'current API function set');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_api_function\":\"assert_screen\",\"check_screen\":{\"check\":0,\"mustmatch\":\"generic-desktop\",\"timeout\":30}}}" });'
        );
        is(js_variable('developerMode.currentApiFunction'), 'assert_screen', 'current API function set');
        is(js_variable('developerMode.currentApiFunctionArgs'), 'generic-desktop', 'current API function set');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_api_function\":\"wait_serial\"}}" });'
        );
        is(js_variable('developerMode.currentApiFunction'), 'wait_serial', 'current API function set');
        is(js_variable('developerMode.currentApiFunctionArgs'), '', 'current API function set');

        $driver->execute_script(
'handleMessageFromWebsocketConnection(developerMode.wsConnection, { data: "{\"type\":\"info\",\"what\":\"cmdsrvmsg\",\"data\":{\"current_api_function\":\"assert_screen\",\"check_screen\":{\"check\":0,\"mustmatch\":[\"foo\",\"bar\"],\"timeout\":30}}}" });'
        );
        is(js_variable('developerMode.currentApiFunction'), 'assert_screen', 'current API function set');
        is_deeply(js_variable('developerMode.currentApiFunctionArgs'), ['foo', 'bar'], 'current API function set');
    };

    subtest 'error handling, flash messages' => sub {
        $driver->execute_script(
            'handleMessageFromWebsocketConnection("foo", { data: "{\"type\":\"error\",\"what\":\"some error\"}" });');
        assert_flash_messages(any => [], 'messsages not from current connection ignored');

        $driver->execute_script('handleMessageFromWebsocketConnection(developerMode.wsConnection, { });');
        assert_flash_messages(any => [], 'messages with no data are ignored');

        # define messages which should lead to errors
        my $invalid_message = 'invalid { json';
        my $error = '{\"type\":\"error\",\"what\":\"some error\"}';
        my $another_error = '{\"type\":\"error\",\"what\":\"another error\"}';
        my $not_ignored_connection_error
          = '{\"type\":\"error\",\"what\":\"not ignored error\",\"data\":{\"category\":\"cmdsrv-connection\"}}';
        my $ignored_connection_error
          = '{\"type\":\"error\",\"what\":\"ignored error\",\"data\":{\"category\":\"cmdsrv-connection\"}}';

 # assume there's no running module (so connection issues with os-autoinst are expected and errors regarding it ignored)
        fake_state(testStatus => {running => 'null'});

        # let the JavaScript code process those errors
        fake_message_from_ws_connection($invalid_message);
        fake_message_from_ws_connection($error);
        fake_message_from_ws_connection($error);    # should not be shown twice
        fake_message_from_ws_connection($another_error);
        fake_message_from_ws_connection($ignored_connection_error);

        # assume there's a running module (so connection issues with os-autoinst are treated as errors)
        fake_state(testStatus => {running => '"foo"'});
        fake_message_from_ws_connection($not_ignored_connection_error);

        assert_flash_messages(
            danger => [qr/Unable to parse/, qr/some error/, qr/another error/, qr/not ignored error/],
            'errors shown via flash messages, same error not shown twice'
        );
        like $driver->find_element('#developer-flash-messages .alert span a')->get_text, qr/documentation/,
          'link to docs present';

        subtest 'dismissed message appears again' => sub {
            # click "X" button of 2nd flash message
            $driver->execute_script('$(".alert-danger").removeClass("fade")');    # prevent delay due to animation
            $driver->execute_script('$($(".alert-danger")[1]).find("button").click();');

            assert_flash_messages(
                danger => [qr/Unable to parse/, qr/another error/, qr/not ignored error/],
                'flash message "some error" dismissed'
            );
            fake_message_from_ws_connection($error);
            assert_flash_messages(
                danger => [qr/Unable to parse/, qr/another error/, qr/not ignored error/, qr/some error/],
                'unique flash message appears again after dismissed'
            );
        };

        $driver->execute_script('handleWebsocketConnectionOpened();');
        assert_flash_messages(any => [], 'obsolete messages cleared after successful connect');
    };
};

kill_driver();
done_testing();
