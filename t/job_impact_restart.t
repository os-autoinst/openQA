# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use utf8;
use Mojo::Base -signatures;
use Test::Mojo;

use OpenQA::Test::Case;
use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME DEFAULT_TIMEOUT_SCALE);
use OpenQA::Jobs::Constants;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $jobs = $schema->resultset('Jobs');

subtest 'restart impact estimation for single job' => sub {
    my $job = $jobs->find(99926);
    my $estimate = $job->restart_impact_estimate;
    ok $estimate, 'returns restart impact estimate';
    is $estimate->{jobs}, 1, 'job count is 1 for non-cluster job';
    ok $estimate->{seconds} > 0, 'estimated seconds > 0';
    ok $estimate->{cost_total} > 0, 'estimated cost_total > 0';
    ok $estimate->{carbon_g} > 0, 'estimated carbon_g > 0';
    is $estimate->{currency}, 'EUR', 'currency is EUR';
};

subtest 'restart impact estimation with skip options' => sub {
    my $job = $jobs->find(99946);
    my $estimate_all = $job->restart_impact_estimate;
    my $estimate_skip_parents = $job->restart_impact_estimate({skip_parents => 1});
    ok $estimate_all, 'estimate calculated for clustered job';
    ok $estimate_skip_parents, 'estimate calculated with skip_parents';
    ok $estimate_skip_parents->{jobs} <= $estimate_all->{jobs}, 'skipping parents clones fewer or equal jobs';
};

subtest 'restart impact estimation with previous attempts' => sub {
    my $orig_job = $jobs->find(99947);
    $orig_job->create_related(
        'impact',
        {
            seconds => 1200,
            vcpus => 1,
            ram_gb => 1,
            power_w => 30,
            energy_kwh => 0.015,
            carbon_g => 5,
            cost_energy => 0.003,
            cost_hardware => 0.003,
            cost_total => 0.006,
            currency => 'EUR',
            model_version => 1,
            factors => {},
        }) unless $orig_job->impact;

    my $clone = $jobs->create(
        {
            TEST => $orig_job->TEST,
            DISTRI => $orig_job->DISTRI,
            VERSION => $orig_job->VERSION,
            FLAVOR => $orig_job->FLAVOR,
            ARCH => $orig_job->ARCH,
            MACHINE => $orig_job->MACHINE,
            state => DONE,
            result => FAILED,
            clone_id => $orig_job->id,
            restart_origin => RESTART_ORIGIN_USER,
        });
    $clone->create_related(
        'impact',
        {
            seconds => 1800,
            vcpus => 1,
            ram_gb => 1,
            power_w => 30,
            energy_kwh => 0.02,
            carbon_g => 7,
            cost_energy => 0.004,
            cost_hardware => 0.005,
            cost_total => 0.009,
            currency => 'EUR',
            model_version => 1,
            factors => {},
        });

    my $estimate = $clone->restart_impact_estimate;
    ok $estimate->{previous_attempts}, 'previous_attempts field exists';
    ok $estimate->{previous_attempts}->{count} >= 1, 'previous_attempts count recorded';
    ok $estimate->{previous_attempts}->{cost_total} > 0, 'previous attempts cost summed';
};

subtest 'restart impact estimate disabled' => sub {
    my $job = $jobs->find(99926);
    local $t->app->config->{job_impact}->{enabled} = 0;
    is $job->restart_impact_estimate, undef, 'returns undef when job_impact.enabled is 0';
};

subtest 'restart estimate API endpoint' => sub {
    $t->get_ok('/api/v1/jobs/99926/restart_estimate')->status_is(200);
    my $json = $t->tx->res->json;
    ok exists $json->{cost_total}, 'endpoint returns cost_total';
    ok exists $json->{jobs}, 'endpoint returns jobs count';

    $t->get_ok('/api/v1/jobs/999999999/restart_estimate')->status_is(404);
};

done_testing;
