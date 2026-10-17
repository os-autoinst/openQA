#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::Output qw(combined_like);

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Mojolicious;
use OpenQA::App;
use OpenQA::Schema::ResultSet::Jobs;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '18';
use Test::Mojo;
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

    is_deeply parse_lifecycle_rules({job_settings_lifecycle => {}}), [], 'Empty section returns empty arrayref';
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

    is scalar(check_setting('TEST_VAR', undef, $rules)), 1, 'Undef value handled as empty string';
};

subtest 'check_settings' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:10:Exp 1',
            r2 => 'K2:!~v2:error:Exp 2',
        }};
    my $rules = parse_lifecycle_rules($config);

    my @m_hash = check_settings({K1 => 'v1', K2 => 'something_else', K3 => 'safe'}, $rules);
    is scalar(@m_hash), 2, 'Found 2 matches in hash';
    is $m_hash[0]->{key}, 'K1', 'Matches are ordered by setting key';
};

subtest 'validate_settings_for_submission' => sub {
    my $config = {
        job_settings_lifecycle => {
            r1 => 'K1:=~v1:warning:10:Exp 1',
            r2 => 'K2:!~v2:error:Exp 2',
        }};

    is validate_settings_for_submission({K1 => 'v1', K2 => 'v2'}, $config), undef, 'No errors for valid settings';

    my $err = validate_settings_for_submission({K1 => 'v1', K2 => 'something_else'}, $config);
    like $err, qr/Setting 'K2' has deprecated value 'something_else': Exp 2/, 'Correct error message returned';
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

subtest 'settings and details pages show lifecycle notices' => sub {
    OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    my $config = $t->app->config;
    $config->{job_settings_lifecycle} = {
        r_warn => 'WARN_KEY:=~warn_val:warning:10:Warning setting explanation',
        r_err => 'ERR_KEY:=~err_val:error:Error setting explanation',
    };
    delete $config->{misc_limits}->{job_settings_lifecycle_rules};

    my $jobs = $t->app->schema->resultset('Jobs');
    $jobs->find(99981)->settings->create({key => 'WARN_KEY', value => 'warn_val'});
    $jobs->find(99961)->settings->create({key => 'ERR_KEY', value => 'err_val'});

    $t->get_ok('/tests/99981/settings_ajax')->status_is(200)
      ->content_like(qr/Deprecated settings found/, 'alert shown for warning')
      ->content_like(qr/Warning setting explanation/, 'warning explanation shown')
      ->text_is('.alert-warning span.badge' => 'Warning', 'warning badge uses sentence case')->text_like(
        'span.badge[title="Warning setting explanation"]' => qr/^\s*Warning\s*$/,
        'table badge uses sentence case'
      );
    $t->get_ok('/tests/99961/settings_ajax')->status_is(200)
      ->text_is('.alert-danger span.badge' => 'Error', 'error badge uses sentence case');
    $t->get_ok('/tests/99963/settings_ajax')->status_is(200)
      ->content_unlike(qr/Deprecated settings found/, 'no alert without deprecated settings');

    $t->get_ok('/tests/99981')->status_is(200)
      ->element_exists('span.bg-warning[title="Deprecated settings detected"]', 'warning badge on test details');
    $t->get_ok('/tests/99961')->status_is(200)
      ->element_exists('span.bg-danger[title="Deprecated settings detected"]', 'error badge on test details');
    $t->get_ok('/tests/99963')->status_is(200)
      ->element_exists_not('span[title="Deprecated settings detected"]', 'no badge without deprecated settings');
};

done_testing();
