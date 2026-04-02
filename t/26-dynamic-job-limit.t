#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(simulate_load);
use Test::MockModule;
use Test::Output qw(combined_like);
use OpenQA::Utils qw(load_avg);
use OpenQA::Scheduler::DynamicLimit qw(MIN STEP EMERGENCY_STEP_MULTIPLIER);

sub test_load_avg ($name, $content, $expected, $msg = undef) {
    subtest $name => sub {
        my $safe_name = $name =~ s{[ /]+}{_}gr;
        my $f = simulate_load($content, "26-load-$safe_name");
        my $load;
        if (ref $expected eq 'Regexp') {
            combined_like { $load = load_avg() } $expected, $msg;
            is_deeply $load, [], 'empty arrayref on error';
        }
        else {
            $load = load_avg();
            is_deeply $load, $expected, $msg // 'correct load values parsed';
        }
    };
}

test_load_avg('reads /proc/loadavg', '1.23 4.56 7.89 2/512 1234', [1.23, 4.56, 7.89]);
test_load_avg(
    'returns empty arrayref on invalid file',
    'not_a_number',
    qr/Unable to parse system load/,
    'parse error logged'
);
test_load_avg(
    'returns empty arrayref when file has fewer than 3 fields',
    '1.0 2.0',
    qr/Unable to parse system load/,
    'parse error logged for truncated file'
);

subtest 'load_avg returns empty arrayref on missing file' => sub {
    local $ENV{OPENQA_LOAD_AVG_FILE} = '/nonexistent/loadavg';
    my $load;
    combined_like { $load = load_avg() } qr/Unable to determine average load/, 'warning logged on missing file';
    is_deeply $load, [], 'empty arrayref on missing file';
};

sub _config (%args) {
    my %config = (
        max_running_jobs => $args{max} // 200,
        dynamic_job_limit_enabled => 1,
    );
    my %map = (
        min => 'dynamic_job_limit_min',
        threshold => 'dynamic_job_limit_load_threshold',
        threshold_factor => 'dynamic_job_limit_load_threshold_factor',
        critical => 'dynamic_job_limit_load_critical',
        critical_factor => 'dynamic_job_limit_load_critical_factor',
        step => 'dynamic_job_limit_step',
        interval => 'dynamic_job_limit_interval',
        hysteresis => 'dynamic_job_limit_scale_up_hysteresis',
        fast_up_factor => 'dynamic_job_limit_fast_ramp_up_load_factor',
    );
    for my $k (keys %args) {
        $config{$map{$k} // $k} = $args{$k} if defined $args{$k} && exists $map{$k};
    }
    return \%config;
}

sub test_dynamic_limit (%args) {
    my $name = $args{name};
    subtest $name => sub {
        my $safe_name = $name =~ s{[ /]+}{_}gr;
        my $f = simulate_load(($args{load} // '1.0 1.0 1.0') . ' 1/1 1', "26-dyn-$safe_name");
        my $dl = OpenQA::Scheduler::DynamicLimit->new;
        $dl->effective_limit($args{initial}) if defined $args{initial};
        $args{block} ? $dl->block_adjustment_for : $dl->force_next_adjustment;
        my %conf = (threshold => 8, critical => 16, max => 200, %{$args{config} // {}});
        my $limit = $dl->current_limit(_config(%conf));
        is $limit, $args{expected}, $args{message} // "limit is $args{expected}";
    };
}

my @cases = (
    {name => 'initial', block => 1, expected => MIN, config => {interval => 60}},
    {name => 'scales up', initial => 100, load => '4.0 4.0 4.0', expected => 100 + STEP},
    {name => 'fast up', initial => 100, load => '1.0 1.0 1.0', expected => 100 + STEP * 2},
    {name => 'steady', initial => 100, load => '6.0 6.5 6.0', expected => 100},
    {name => 'scales down', initial => 100, load => '10.0 7.0 6.0', expected => 100 - STEP},
    {
        name => 'emergency',
        initial => 100,
        load => '20.0 18.0 15.0',
        expected => 100 - STEP * EMERGENCY_STEP_MULTIPLIER,
        config => {critical => 16}
    },
    {name => 'floor', load => '20.0 18.0 15.0', initial => MIN + 5, expected => MIN, config => {critical => 16}},
    {name => 'ceiling', load => '1.0 1.0 1.0', initial => 195, expected => 200},
    {
        name => 'gating',
        initial => 100,
        load => '20.0 18.0 15.0',
        block => 1,
        expected => 100,
        config => {interval => 60}
    },
    {name => 'unlimited', initial => 100, load => '4.0 4.0 4.0', expected => 100 + STEP, config => {max => -1}},
);

test_dynamic_limit(%$_) for @cases;

subtest 'auto-detects threshold from nproc when configured as 0' => sub {
    local $OpenQA::Scheduler::DynamicLimit::FIXED_NPROC
      = 4;    # 4 CPUs; threshold = 4*0.85 = 3.4; load 1.0 < 3.4*0.3=1.02 => fast up
    test_dynamic_limit(
        name => 'autothresh',
        initial => 100,
        load => '1.0 1.0 1.0',
        expected => 100 + STEP * 2,
        config => {threshold => 0});
};

subtest 'auto-detects threshold from nproc (1 CPU)' => sub {
    local $OpenQA::Scheduler::DynamicLimit::FIXED_NPROC = 1;  # 1 CPU; threshold = 1*0.85 = 0.85; critical = 1*1.5 = 1.5
    test_dynamic_limit(
        name => 'autothresh_1cpu_scale_up',
        initial => 100,
        load => '0.2 0.2 0.2',
        # threshold = 0.85. 0.2 < 0.85*0.3 = 0.255. Fast up.
        expected => 100 + STEP * 2,
        config => {threshold => 0, critical => 0});
    test_dynamic_limit(
        name => 'autothresh_1cpu_emergency',
        initial => 100,
        load => '2.0 2.0 2.0',
        # critical = 1.5. 2.0 > 1.5. Emergency.
        expected => 100 - STEP * EMERGENCY_STEP_MULTIPLIER,
        config => {threshold => 0, critical => 0});
};

subtest '_nproc returns positive number of CPUs' => sub {
    my $nproc = OpenQA::Scheduler::DynamicLimit::_nproc();
    cmp_ok $nproc, '>', 0, '_nproc returns a positive integer';
    like $nproc, qr/^\d+$/, '_nproc returns a digit';
};

done_testing;
