#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::MockObject;
use Test::Output qw(combined_like);

use FindBin;
use lib "$FindBin::Bin/../lib";

use Mojolicious;
use OpenQA::App;
use OpenQA::Schema::ResultSet::Jobs;
use OpenQA::WebAPI::Controller::Test;
use OpenQA::JobSettings::Lifecycle qw(
  parse_lifecycle_rules
  check_setting
  check_settings
  validate_settings_for_submission
  apply_lifecycle_prio
  lifecycle_matches
  worst_level
);

subtest 'parse_lifecycle_rules' => sub {
    my $config = {
        job_settings_lifecycle => {
            rule1 => 'UEFI_PFLASH_CODE:=~ovmf-.*-unsupported:warning:30:Use released OVMF packages instead',
            rule2 => 'OBSOLETE_SETTING:=~.*:error:OBSOLETE_SETTING has been removed',
            rule3 => 'NOT_RECOMMENDED:!~^good_val$:warning:NOT_RECOMMENDED should not have that value',
            rule4 => 'INVALID_REGEX:=~(unclosed:error:This won\'t compile',
            rule5 => 'NEGATIVE_PRIO:=~bad:warning:-10:Lowered priority',
            rule6 => 'SIGNED_PRIO:=~signed:warning:+15:Signed priority adjustment',
        }};

    my $rules;
    combined_like { $rules = parse_lifecycle_rules($config) } qr/Invalid lifecycle rule regex for 'rule4'/,
      'warns about invalid regex';
    is scalar(@$rules), 5, 'Successfully parsed 5 valid rules, skipped 1 invalid regex';

    is $rules->[0]->{id}, 'rule1', 'rule1 id matches';
    is $rules->[0]->{key}, 'UEFI_PFLASH_CODE', 'rule1 key matches';
    is $rules->[0]->{op}, '=~', 'rule1 op defaults/matches =~';
    is $rules->[0]->{level}, 'warning', 'rule1 level matches';
    is $rules->[0]->{prio}, 30, 'rule1 prio matches';
    is $rules->[0]->{explanation}, 'Use released OVMF packages instead', 'rule1 explanation matches';

    is $rules->[1]->{id}, 'rule2', 'rule2 id matches';
    is $rules->[1]->{key}, 'OBSOLETE_SETTING', 'rule2 key matches';
    is $rules->[1]->{level}, 'error', 'rule2 level matches';
    is $rules->[1]->{prio}, undef, 'rule2 has no prio';
    is $rules->[1]->{explanation}, 'OBSOLETE_SETTING has been removed', 'rule2 explanation matches';

    is $rules->[2]->{id}, 'rule3', 'rule3 id matches';
    is $rules->[2]->{op}, '!~', 'rule3 has inverse op';
    is $rules->[2]->{prio}, undef, 'rule3 has no prio';
    is $rules->[2]->{explanation}, 'NOT_RECOMMENDED should not have that value', 'rule3 explanation matches';

    is $rules->[3]->{id}, 'rule5', 'rule5 id matches';
    is $rules->[3]->{prio}, -10, 'rule5 has negative prio';

    is $rules->[4]->{id}, 'rule6', 'rule6 id matches';
    is $rules->[4]->{prio}, 15, 'rule6 signed prio normalized to integer';

    my $cached_rules = parse_lifecycle_rules($config);
    is $cached_rules, $rules, 'Returns cached rules array ref';
    is $config->{misc_limits}->{job_settings_lifecycle_rules}, $rules, 'Rules cached in misc_limits';

    delete $config->{misc_limits}->{job_settings_lifecycle_rules};
    my $reparsed_rules;
    combined_like { $reparsed_rules = parse_lifecycle_rules($config) } qr/Invalid lifecycle rule regex for 'rule4'/,
      'warns again when re-parsing after cache reset';
    isnt $reparsed_rules, $rules, 'Re-parsed rules array ref is new after cache reset';
    is_deeply $reparsed_rules, $rules, 'Re-parsed rules content matches';

    is_deeply parse_lifecycle_rules(undef), [], 'Undef config returns empty arrayref';
    is_deeply parse_lifecycle_rules({}), [], 'Empty config returns empty arrayref';
    is_deeply parse_lifecycle_rules({job_settings_lifecycle => 'not_a_hash'}), [],
      'Non-hash section returns empty arrayref';
};

subtest 'check_setting' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'TEST_VAR:=~abc:warning:30:Warning explanation',
            r2 => 'TEST_VAR:!~abc:error:Error explanation',
        }};
    my $rules = parse_lifecycle_rules($config);

    my @m1 = check_setting('TEST_VAR', 'abcde', $rules);
    is scalar(@m1), 1, 'Matched =~ rule';
    is $m1[0]->{level}, 'warning', 'Matched level is warning';
    is $m1[0]->{explanation}, 'Warning explanation', 'Matched explanation';

    my @m2 = check_setting('TEST_VAR', 'other', $rules);
    is scalar(@m2), 1, 'Matched !~ rule';
    is $m2[0]->{level}, 'error', 'Matched level is error';

    my @m3 = check_setting('TEST_VAR', 'abc', $rules);
    is scalar(@m3), 1, 'Matches only =~abc';

    my @m4 = check_setting('OTHER_VAR', 'abc', $rules);
    is scalar(@m4), 0, 'No match for non-existent setting keys';

    is scalar(check_setting(undef, 'val', $rules)), 0, 'Undef key returns empty list';
    is scalar(check_setting('TEST_VAR', undef, $rules)), 1, 'Undef value handled as empty string';
    is scalar(check_setting('TEST_VAR', 'abc', undef)), 0, 'Undef rules returns empty list';
};

subtest 'check_settings' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:10:Exp 1',
            r2 => 'K2:!~v2:error:Exp 2',
        }};
    my $rules = parse_lifecycle_rules($config);

    my $settings_hash = {K1 => 'v1', K2 => 'something_else', K3 => 'safe'};
    my @m_hash = check_settings($settings_hash, $rules);
    is scalar(@m_hash), 2, 'Found 2 matches in hash';

    my $settings_array = [K1 => 'v1', K2 => 'v2'];
    my @m_array = check_settings($settings_array, $rules);
    is scalar(@m_array), 1, 'Found 1 match in flat array';
    is $m_array[0]->{key}, 'K1', 'Matched key is K1';

    my $settings_array_hashes = [{key => 'K1', value => 'v1'}, {key => 'K2', value => 'something_else'}, {other => 1}];
    my @m_array_hashes = check_settings($settings_array_hashes, $rules);
    is scalar(@m_array_hashes), 2, 'Found 2 matches in array of hashes, skipped hash without key';

    is scalar(check_settings(undef, $rules)), 0, 'Undef settings returns empty list';
    is scalar(check_settings($settings_hash, undef)), 0, 'Undef rules returns empty list';
};

subtest 'validate_settings_for_submission' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:10:Exp 1',
            r2 => 'K2:!~v2:error:Exp 2',
        }};
    my $rules = parse_lifecycle_rules($config);

    is validate_settings_for_submission({K1 => 'v1', K2 => 'v2'}, $rules), undef, 'No errors for valid settings';

    my $err = validate_settings_for_submission({K1 => 'v1', K2 => 'something_else'}, $rules);
    like $err, qr/Setting 'K2' has deprecated value 'something_else': Exp 2/, 'Correct error message returned';

    is validate_settings_for_submission({K1 => 'v1'}, undef), undef, 'Undef rules returns undef';
};

subtest 'apply_lifecycle_prio' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:20:Exp 1',
            r2 => 'K2:=~v2:error:-5:Exp 2',
            r3 => 'K3:=~v3:warning:No prio adjustment',
        }};
    my $rules = parse_lifecycle_rules($config);

    my $settings = {K1 => 'v1', K2 => 'v2', K3 => 'v3'};
    my $new_job_args = {priority => 50};
    my $throttling_info = [];

    apply_lifecycle_prio($settings, $new_job_args, $throttling_info, $rules);

    is $new_job_args->{priority}, 65, 'Priority adjusted (50 + 20 - 5 = 65)';
    is scalar(@$throttling_info), 2, 'Throttling info recorded only rules with prio adjustment';
    is $throttling_info->[0], 'K1 [+20: value v1]', 'Throttling info format for positive adjustment';
    is $throttling_info->[1], 'K2 [-5: value v2]', 'Throttling info format for negative adjustment';

    my $uninit_args = {};
    apply_lifecycle_prio({K1 => 'v1'}, $uninit_args, [], $rules);
    is $uninit_args->{priority}, 20, 'Uninitialized priority defaults to 0 and adds adjustment';

    apply_lifecycle_prio($settings, $new_job_args, [], undef);
    is $new_job_args->{priority}, 65, 'Undef rules does not change priority';
};

subtest 'Jobs::_apply_prio_throttling' => sub {
    my $app = Mojolicious->new;
    $app->config->{job_settings_lifecycle} = {rule1 => 'DEPR_KEY:=~val:warning:25:De-prioritized deprecated setting',};
    $app->config->{misc_limits} = {throttle_failing_job_threshold => 0};
    my $app_mock = Test::MockModule->new('OpenQA::App');
    $app_mock->redefine(singleton => sub { $app });

    my $jobs_rs = bless {}, 'OpenQA::Schema::ResultSet::Jobs';
    my $settings = {DEPR_KEY => 'val'};
    my $new_job_args = {priority => 50};
    my $debug_msg = $jobs_rs->_apply_prio_throttling($settings, $new_job_args);

    is $new_job_args->{priority}, 75, 'Priority adjusted from 50 to 75';
    like $debug_msg, qr/DEPR_KEY \[\+25: value val\]/, 'Throttling debug message contains lifecycle info';
};

subtest 'controller settings and show actions' => sub {
    my $app = Mojolicious->new;
    $app->log->level('fatal');
    $app->config->{job_settings_lifecycle} = {
        r_warn => 'WARN_KEY:=~warn_val:warning:10:Warning setting explanation',
        r_err => 'ERR_KEY:=~err_val:error:Error setting explanation',
    };
    $app->helper('reply.not_found' => sub { 'not_found' });
    $app->plugin('OpenQA::WebAPI::Plugin::Helpers');

    my $mock_job = Test::MockObject->new;
    $mock_job->mock(settings_hash => sub { {WARN_KEY => 'warn_val'} });
    $mock_job->mock(redacted_settings_hash => sub { {WARN_KEY => 'warn_val'} });
    $mock_job->mock(name => sub { 'testjob' });
    $mock_job->mock(DISTRI => sub { 'opensuse' });
    $mock_job->mock(VERSION => sub { '15.5' });
    $mock_job->mock(BUILD => sub { '1' });
    $mock_job->mock(scenario_name => sub { 'scenario' });
    $mock_job->mock(worker => sub { undef });
    $mock_job->mock(assigned_worker => sub { undef });
    $mock_job->mock(has_dependencies => sub { 0 });
    $mock_job->mock(should_show_autoinst_log => sub { 0 });
    $mock_job->mock(should_show_investigation => sub { 0 });
    $mock_job->mock(state => sub { 'done' });
    $mock_job->mock(gru_dependencies => sub { () });
    $mock_job->mock(ancestors => sub { [] });
    $mock_job->mock(
        comments => sub {
            Test::MockObject->new->mock(count => sub { 0 });
        });
    $mock_job->mock(id => sub { 42 });

    my $c = OpenQA::WebAPI::Controller::Test->new(app => $app);
    my $controller_mock = Test::MockModule->new('OpenQA::WebAPI::Controller::Test');
    $controller_mock->redefine(_stash_job => sub { $mock_job });
    $controller_mock->redefine(_stash_clone_info => sub { 1 });
    $controller_mock->redefine(_gru_tasks_items => sub { [] });
    $controller_mock->redefine(render => sub { 1 });

    $c->settings;
    is $c->stash('has_deprecated_settings'), 1, 'Settings action detects deprecated settings';
    ok exists $c->stash('deprecated_settings')->{WARN_KEY}, 'Deprecated settings hash contains WARN_KEY';

    $controller_mock->redefine(_stash_job => sub { undef });
    is $c->settings, 'not_found', 'Settings action returns not_found when job cannot be stashed';
    $controller_mock->redefine(_stash_job => sub { $mock_job });

    is $c->_show(undef), 'not_found', '_show action returns not_found when job is undef';

    $c->_show($mock_job);
    is $c->stash('has_deprecated_settings'), 1, '_show action detects deprecated settings';
    is $c->stash('deprecated_level'), 'warning', '_show action assigns warning level when only warnings match';

    $mock_job->mock(settings_hash => sub { {ERR_KEY => 'err_val', WARN_KEY => 'warn_val'} });
    $c->_show($mock_job);
    is $c->stash('deprecated_level'), 'error', '_show action assigns error level when error matches';

    $mock_job->mock(settings_hash => sub { {SAFE_KEY => 'safe_val'} });
    $c->_show($mock_job);
    is $c->stash('has_deprecated_settings'), 0, '_show action sets has_deprecated_settings to 0 when no match';
};

subtest 'template rendering' => sub {
    my $app = Mojolicious->new;
    $app->log->level('fatal');
    $app->renderer->paths(["$FindBin::Bin/../templates/webapi"]);
    $app->helper(link_key_exists => sub { 0 });
    $app->helper(setting_link => sub { 'link' });
    $app->helper(icon_url => sub { 'icon' });
    $app->helper(asset => sub { '' });
    $app->helper(url_for => sub { '/url' });
    $app->helper(include => sub { '' });
    $app->helper(layout => sub { '' });

    my $mock_job = Test::MockObject->new;
    $mock_job->mock(redacted_settings_hash => sub { {KEY => 'val'} });
    $mock_job->mock(
        comments => sub {
            Test::MockObject->new->mock(count => sub { 0 });
        });
    $mock_job->mock(id => sub { 123 });
    $mock_job->mock(state => sub { 'done' });
    $mock_job->mock(result => sub { 'passed' });
    $mock_job->mock(name => sub { 'test' });

    subtest 'Error-level in settings template' => sub {
        my $c1 = $app->build_controller;
        $c1->stash(
            job => $mock_job,
            has_deprecated_settings => 1,
            deprecated_settings => {KEY => {level => 'error', explanation => 'some error explanation'}},
            deprecated_level => 'error',
        );
        my $rendered1 = $c1->render_to_string('test/settings');
        like $rendered1, qr/Deprecated settings found/, 'Renders error alert block in settings';
        like $rendered1, qr/some error explanation/, 'Renders explanation in settings';
        like $rendered1, qr/alert-danger/, 'Renders alert-danger class';
        like $rendered1, qr/bg-danger/, 'Renders bg-danger class on badge';
    };

    subtest 'Warning-level in settings template' => sub {
        my $c2 = $app->build_controller;
        $c2->stash(
            job => $mock_job,
            has_deprecated_settings => 1,
            deprecated_settings => {KEY => {level => 'warning', explanation => 'some warning explanation'}},
            deprecated_level => 'warning',
        );
        my $rendered2 = $c2->render_to_string('test/settings');
        like $rendered2, qr/alert-warning/, 'Renders alert-warning class';
        like $rendered2, qr/bg-warning text-dark/, 'Renders bg-warning class on badge';
    };

    subtest 'No deprecated settings in settings template' => sub {
        my $c3 = $app->build_controller;
        $c3->stash(job => $mock_job, has_deprecated_settings => 0);
        my $rendered3 = $c3->render_to_string('test/settings');
        unlike $rendered3, qr/Deprecated settings found/, 'Does not render alert block when no deprecated settings';
    };

    subtest 'Result template tab badges' => sub {
        my $cr1 = $app->build_controller;
        $cr1->stash(
            job => $mock_job,
            testid => 123,
            has_deprecated_settings => 1,
            deprecated_level => 'error',
            assigned_worker => undef,
            show_dependencies => 0,
            show_investigation => 0,
            show_autoinst_log => 0,
            show_live_tab => 0,
        );
        my $res1 = $cr1->render_to_string('test/result');
        like $res1, qr/badge bg-danger/, 'Renders danger badge on Settings tab in result.html.ep';

        my $cr2 = $app->build_controller;
        $cr2->stash(
            job => $mock_job,
            testid => 123,
            has_deprecated_settings => 1,
            deprecated_level => 'warning',
            assigned_worker => undef,
            show_dependencies => 0,
            show_investigation => 0,
            show_autoinst_log => 0,
            show_live_tab => 0,
        );
        my $res2 = $cr2->render_to_string('test/result');
        like $res2, qr/badge bg-warning text-dark/, 'Renders warning badge on Settings tab in result.html.ep';

        my $cr3 = $app->build_controller;
        $cr3->stash(
            job => $mock_job,
            testid => 123,
            has_deprecated_settings => 0,
            assigned_worker => undef,
            show_dependencies => 0,
            show_investigation => 0,
            show_autoinst_log => 0,
            show_live_tab => 0,
        );
        my $res3 = $cr3->render_to_string('test/result');
        unlike $res3, qr/Deprecated settings detected/, 'No badge rendered on Settings tab when no deprecated settings';
    };
};

subtest 'lifecycle_matches' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:10:Exp 1',
            r2 => 'K2:!~v2:error:Exp 2',
        }};
    my $settings = {K1 => 'v1', K2 => 'something_else', K3 => 'safe'};

    my @matches = lifecycle_matches($config, $settings);
    is scalar(@matches), 2, 'Returns list in list context';
};

subtest 'worst_level data-driven' => sub {
    my @test_cases = (
        {
            matches => undef,
            expected => undef,
            desc => 'Undef matches returns undef',
        },
        {
            matches => [],
            expected => undef,
            desc => 'Empty arrayref returns undef',
        },
        {
            matches => [{level => 'info'}],
            expected => 'info',
            desc => 'Only info returns info',
        },
        {
            matches => [{level => 'info'}, {level => 'warning'}],
            expected => 'warning',
            desc => 'info and warning returns warning',
        },
        {
            matches => [{level => 'warning'}, {level => 'error'}, {level => 'info'}],
            expected => 'error',
            desc => 'warning, error, and info returns error',
        },
        {
            matches => {level => 'warning'},
            expected => 'warning',
            desc => 'Single match hashref handled and returns warning',
        },
        {
            matches => [{level => 'unknown'}],
            expected => undef,
            desc => 'Unknown level in matches returns undef',
        },
    );

    for my $case (@test_cases) {
        my $res = worst_level($case->{matches});
        is $res, $case->{expected}, $case->{desc};
    }
};

subtest 'parse_lifecycle_rules invalid inputs and escaping' => sub {
    my $config = {
        job_settings_lifecycle => {
            r_bad_format_no_colons => 'UEFI_PFLASH_CODE',
            r_bad_format_one_colon => 'UEFI_PFLASH_CODE:=~unsupported',
            r_bad_format_two_colons => 'UEFI_PFLASH_CODE:=~unsupported:warning',
            r_bad_format_empty_pattern => 'UEFI_PFLASH_CODE::warning:explanation',
            r_bad_format_empty_key => ':pattern:warning:explanation',
            r_invalid_level => 'UEFI_PFLASH_CODE:=~unsupported:unknown_level:explanation',
            r_invalid_regex => 'UEFI_PFLASH_CODE:=~(unclosed:warning:explanation',
            r_escaped => 'COLON_KEY:=~a\:b:warning:explanation_with:colon',
            r_info => 'INFO_KEY:=~info_val:info:info explanation',
        }};

    my $rules;
    combined_like {
        $rules = parse_lifecycle_rules($config);
    }
qr/Invalid lifecycle rule format for 'r_bad_format_empty_key'.*Invalid lifecycle rule format for 'r_bad_format_empty_pattern'.*Invalid lifecycle rule format for 'r_bad_format_no_colons'.*Invalid lifecycle rule format for 'r_bad_format_one_colon'.*Invalid lifecycle rule format for 'r_bad_format_two_colons'.*Invalid lifecycle rule level 'unknown_level' for 'r_invalid_level'.*Invalid lifecycle rule regex for 'r_invalid_regex'/s,
      'logs correct warnings for invalid rules';

    is scalar(@$rules), 2, 'Successfully parsed only the 2 valid/escaped/info rules';

    subtest 'escaped colons are unescaped and matched literally' => sub {
        is $rules->[0]->{id}, 'r_escaped', 'r_escaped id';
        is $rules->[0]->{key}, 'COLON_KEY', 'r_escaped key';
        is $rules->[0]->{regex_str}, 'a:b', 'regex string unescaped correctly';
        is $rules->[0]->{level}, 'warning', 'r_escaped level';
        is $rules->[0]->{explanation}, 'explanation_with:colon', 'explanation contains colon';
        ok 'a:b' =~ $rules->[0]->{regex}, 'regex compiles and matches literal colon';
    };

    subtest 'info level rules are successfully parsed' => sub {
        is $rules->[1]->{id}, 'r_info', 'r_info id';
        is $rules->[1]->{key}, 'INFO_KEY', 'r_info key';
        is $rules->[1]->{level}, 'info', 'r_info level is info';
        is $rules->[1]->{explanation}, 'info explanation', 'r_info explanation';
    };
};

done_testing();
