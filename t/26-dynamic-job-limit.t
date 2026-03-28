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
use OpenQA::Scheduler::DynamicLimit;

subtest 'load_avg reads /proc/loadavg' => sub {
    my $f = simulate_load('1.23 4.56 7.89 2/512 1234', '26-dynamic-job-limit');
    my $load = load_avg();
    is scalar @$load, 3, 'three load values returned';
    is_deeply $load, [1.23, 4.56, 7.89], 'correct load values parsed';
};

subtest 'load_avg returns empty arrayref on invalid file' => sub {
    my $f = simulate_load('not_a_number', '26-dynamic-job-limit-invalid');
    my $load;
    combined_like { $load = load_avg() } qr/Unable to parse system load/, 'parse error logged';
    is_deeply $load, [], 'empty arrayref on invalid load data';
};

subtest 'load_avg returns empty arrayref when file has fewer than 3 fields' => sub {
    my $f = simulate_load('1.0 2.0', '26-dynamic-job-limit-short');
    my $load;
    combined_like { $load = load_avg() } qr/Unable to parse system load/, 'parse error logged for truncated file';
    is_deeply $load, [], 'empty arrayref when fewer than 3 load values present';
};

subtest 'load_avg returns empty arrayref on missing file' => sub {
    local $ENV{OPENQA_LOAD_AVG_FILE} = '/nonexistent/loadavg';
    my $load;
    combined_like { $load = load_avg() } qr/Unable to determine average load/, 'warning logged on missing file';
    is_deeply $load, [], 'empty arrayref on missing file';
};

sub _config (%args) {
    return {
        max_running_jobs => $args{max} // 200,
        dynamic_job_limit_enabled => 1,
        dynamic_job_limit_min => $args{min} // 50,
        dynamic_job_limit_load_threshold => $args{threshold} // 8,
        dynamic_job_limit_load_critical => $args{critical} // 16,
        dynamic_job_limit_step => $args{step} // 10,
        dynamic_job_limit_interval => $args{interval} // 0,
    };
}

subtest 'initial limit is dynamic_job_limit_min before first adjustment interval' => sub {
    my $f = simulate_load('1.0 1.0 1.0 1/1 1', '26-dyn-initial');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->block_adjustment_for;    # interval not yet elapsed
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, interval => 60));
    is $limit, 50, 'returns min limit when no adjustment has occurred yet';
};

subtest 'scales up when load well below threshold' => sub {
    my $f = simulate_load('1.0 1.0 1.0 1/1 1', '26-dyn-scaleup');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, step => 10, max => 200));
    is $limit, 110, 'increases by step when load well below threshold (1.0 < 8*0.7=5.6)';
};

subtest 'holds steady when load near threshold' => sub {
    # load is above 70% of threshold (5.6) but below threshold (8), not rising
    my $f = simulate_load('6.0 6.5 6.0 1/1 1', '26-dyn-steady');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, step => 10, max => 200));
    is $limit, 100, 'no change when load is near threshold';
};

subtest 'scales down on rising load above threshold' => sub {
    # load_1m (10) > threshold (8) and load_1m (10) > load_5m (7) => rising
    my $f = simulate_load('10.0 7.0 6.0 1/1 1', '26-dyn-scaledown');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, step => 10, max => 200));
    is $limit, 90, 'decreases by step on rising load above threshold';
};

subtest 'emergency cutback on critical load' => sub {
    my $f = simulate_load('20.0 18.0 15.0 1/1 1', '26-dyn-critical');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, critical => 16, step => 10, max => 200));
    is $limit, 70, 'decreases by 3*step on critical load';
};

subtest 'floor enforcement: never below min' => sub {
    my $f = simulate_load('20.0 18.0 15.0 1/1 1', '26-dyn-floor');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(55);    # close to min=50; 3*step=30 would go below
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, critical => 16, step => 10, max => 200));
    is $limit, 50, 'clamped at min limit';
};

subtest 'ceiling enforcement: never above max_running_jobs' => sub {
    my $f = simulate_load('1.0 1.0 1.0 1/1 1', '26-dyn-ceiling');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(195);    # close to max=200; +step=10 would exceed
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, step => 10, max => 200));
    is $limit, 200, 'clamped at max_running_jobs';
};

subtest 'interval gating: no adjustment before interval elapses' => sub {
    my $f = simulate_load('20.0 18.0 15.0 1/1 1', '26-dyn-interval');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->block_adjustment_for;    # interval not yet elapsed
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, critical => 16, step => 10, interval => 60));
    is $limit, 100, 'no change before interval elapses';
};

subtest 'no limit when max_running_jobs is -1 (unlimited)' => sub {
    my $f = simulate_load('1.0 1.0 1.0 1/1 1', '26-dyn-unlimited');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 8, step => 10, max => -1));
    is $limit, 110, 'scales up without ceiling when max_running_jobs=-1';
};

subtest 'auto-detects threshold from nproc when configured as 0' => sub {
    my $mock_dl = Test::MockModule->new('OpenQA::Scheduler::DynamicLimit');
    $mock_dl->mock(_nproc => sub { 4 });    # 4 CPUs; threshold = 4*0.85 = 3.4; load 1.0 < 3.4*0.7=2.38 => scale up
    my $f = simulate_load('1.0 1.0 1.0 1/1 1', '26-dyn-autothresh');
    my $dl = OpenQA::Scheduler::DynamicLimit->new;
    $dl->effective_limit(100);
    $dl->force_next_adjustment;
    my $limit = $dl->current_limit(_config(min => 50, threshold => 0, step => 10, max => 200));
    is $limit, 110, 'scales up with auto-detected threshold (mocked 4 CPUs, load 1.0)';
};

subtest '_nproc returns positive number of CPUs' => sub {
    my $nproc = OpenQA::Scheduler::DynamicLimit::_nproc();
    cmp_ok $nproc, '>', 0, '_nproc returns a positive integer';
    like $nproc, qr/^\d+$/, '_nproc returns a digit';
};

done_testing;
