#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Jobs::Constants;
use OpenQA::JobImpact;
use OpenQA::Test::Case;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::Mojo;
use DateTime;

my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema = OpenQA::Test::Case->new->init_data(
    fixtures_glob => '01-jobs.pl 02-workers.pl',
    schema_name => $schema_name,
);
my $t = Test::Mojo->new('OpenQA::WebAPI');
my ($jobs, $workers) = map { $t->app->schema->resultset($_) } qw(Jobs Workers);

my %default_settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    ISO => 'whatever.iso',
    MACHINE => 'RainbowPC',
    ARCH => 'x86_64',
);

sub _create_job ($extra_settings = {}, $test_name = 'impact_test') {
    my $job = $jobs->create_from_settings({%default_settings, %$extra_settings, TEST => $test_name});
    $job->discard_changes;
    return $job;
}

subtest 'finished job records impact matching assess calculation' => sub {
    my $job = _create_job({QEMUCPUS => 4, QEMURAM => 4096}, 'finished_impact_matching');
    my $start_time = DateTime->now->subtract(seconds => 300);
    $job->update({t_started => $start_time});
    $job->done(result => PASSED);

    my $impact = $job->discard_changes->impact;
    ok $impact, 'impact record created when job is marked done';
    is $impact->job_id, $job->id, 'impact job_id matches finished job';
    ok $impact->seconds >= 300, 'duration recorded as at least elapsed seconds';
    is $impact->vcpus, 4, 'vcpus matches configured QEMUCPUS';
    is $impact->ram_gb, 4, 'ram_gb matches configured QEMURAM in GiB';

    my $factors = OpenQA::JobImpact::resolve_factors(job_settings => $job->settings_hash);
    my $resources = OpenQA::JobImpact::resources($job->settings_hash, $factors);
    my $expected = OpenQA::JobImpact::assess(
        seconds => $impact->seconds,
        resources => $resources,
        factors => $factors,
    );

    is $impact->energy_kwh, $expected->{energy_kwh}, 'energy_kwh matches assess formula output';
    is $impact->carbon_g, $expected->{carbon_g}, 'carbon_g matches assess formula output';
    is $impact->cost_energy, $expected->{cost}->{energy}, 'cost_energy matches assess formula output';
    is $impact->cost_hardware, $expected->{cost}->{hardware}, 'cost_hardware matches assess formula output';
    is $impact->cost_total, $expected->{cost}->{total}, 'cost_total matches assess formula output';
    is $impact->currency, 'EUR', 'currency defaults to EUR';
    is $impact->model_version, 1, 'model_version matches default model version';
    is $impact->factors->{pue}, $factors->{pue}, 'resolved pue stored in factors';
};

subtest 'disabled config writes no impact record' => sub {
    local OpenQA::App->singleton->config->{job_impact}->{enabled} = 0;
    my $job = _create_job({}, 'disabled_config_no_impact');
    $job->update({t_started => DateTime->now->subtract(seconds => 60)});
    $job->done(result => PASSED);

    is $job->discard_changes->impact, undef, 'no impact record stored when job_impact.enabled is false';
};

subtest 'job without t_started writes no impact record' => sub {
    my $job = _create_job({}, 'missing_start_time_no_impact');
    $job->done(result => PASSED);

    is $job->discard_changes->impact, undef, 'no impact record stored when t_started is missing';
};

subtest 'assigned worker impact properties override base factors' => sub {
    my $worker = $workers->first;
    $worker->set_property(JOB_IMPACT_SLOT_POWER_W => 88);

    my $job = _create_job({}, 'worker_factor_override');
    $job->update(
        {
            assigned_worker_id => $worker->id,
            t_started => DateTime->now->subtract(seconds => 120),
        });
    $job->done(result => PASSED);

    my $impact = $job->discard_changes->impact;
    ok $impact, 'impact record created for job with assigned worker';
    is $impact->power_w, 88, 'power_w uses worker slot_power_w property';
    is $impact->factors->{slot_power_w}, 88, 'resolved factors store worker slot_power_w';
    is $impact->factors->{sources}->{slot_power_w}, 'worker', 'source recorded as worker for overridden factor';
};

subtest 'errors in compute_impact are logged and do not break done' => sub {
    my $mock_impact = Test::MockModule->new('OpenQA::JobImpact');
    $mock_impact->redefine(assess => sub { die 'simulated failure in assess' });

    my $logged_warning = '';
    my $mock_jobs = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
    $mock_jobs->redefine(log_warning => sub ($msg, @) { $logged_warning = $msg });

    my $job = _create_job({}, 'assess_failure_resilience');
    $job->update({t_started => DateTime->now->subtract(seconds => 60)});
    my $res = $job->done(result => PASSED);

    is $res, PASSED, 'done returns final result despite exception in compute_impact';
    is $job->discard_changes->state, DONE, 'job state transitioned to DONE';
    is $job->impact, undef, 'no impact record created when assessment throws error';
    like $logged_warning, qr/Failed to compute job impact for job \d+: simulated failure in assess/,
      'warning message logged indicating job ID and reason';
};

subtest 'incomplete jobs with t_started record impact' => sub {
    my @cases = (
        {
            desc => 'job marked incomplete because worker died',
            result => INCOMPLETE,
            reason => 'worker died',
            test_name => 'incomplete_worker_died',
        },
        {
            desc => 'job marked incomplete because timeout exceeded',
            result => TIMEOUT_EXCEEDED,
            reason => 'execution timeout reached',
            test_name => 'incomplete_timeout_exceeded',
        },
    );

    for my $case (@cases) {
        my $job = _create_job({}, $case->{test_name});
        $job->update({t_started => DateTime->now->subtract(seconds => 90)});
        my $res = $job->done(result => $case->{result}, reason => $case->{reason});

        is $res, $case->{result}, "$case->{desc}: done returns $case->{result}";
        my $impact = $job->discard_changes->impact;
        ok $impact, "$case->{desc}: impact record created for incomplete run";
        ok $impact->seconds >= 90, "$case->{desc}: impact duration recorded";
        ok $impact->cost_total > 0, "$case->{desc}: non-zero total cost recorded for elapsed execution";
    }
};

subtest 'recomputing impact updates existing record' => sub {
    my $job = _create_job({}, 'recompute_impact_update');
    $job->update({t_started => DateTime->now->subtract(seconds => 50)});
    $job->done(result => PASSED);

    my $impact_initial = $job->discard_changes->impact;
    ok $impact_initial, 'initial impact record created';

    $job->update({t_started => DateTime->now->subtract(seconds => 200)});
    my $updated_impact = $job->compute_impact;
    ok $updated_impact, 'compute_impact returned updated record';
    is $job->discard_changes->impact->job_id, $job->id, 'impact job_id unchanged after update';
    cmp_ok $job->impact->seconds, '>=', 200, 'impact duration updated to new elapsed seconds';
};

done_testing;
