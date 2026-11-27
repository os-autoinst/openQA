#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Mojo::Base -signatures;
use OpenQA::Test::Case;
use OpenQA::JobImpact qw(resolve_factors);

my $schema = OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl');
my $workers = $schema->resultset('Workers');
my $worker = $workers->find(1);

subtest 'empty job impact factors when no impact properties exist' => sub {
    is_deeply $worker->job_impact_factors, {}, 'returns empty hash when worker has no impact properties';
};

subtest 'extract and normalize worker job impact factors' => sub {
    $worker->set_property('JOB_IMPACT_SLOT_POWER_W', '150');
    $worker->set_property('JOB_IMPACT_HW_EUR_PER_SLOT_HOUR', '0.05');
    $worker->set_property('JOB_IMPACT_INVALID_NON_NUMERIC', 'not_a_number');
    $worker->set_property('JOB_IMPACT_NEGATIVE_VALUE', '-25');

    is_deeply $worker->job_impact_factors,
      {
        slot_power_w => 150,
        hw_eur_per_slot_hour => 0.05,
      },
      'returns stripped lowercase numeric factors and ignores non-numeric or negative values';
};

subtest 'integration between worker factors and resolve_factors' => sub {
    my $factors = $worker->job_impact_factors;
    my $resolved = resolve_factors(worker_props => $factors);

    is $resolved->{slot_power_w}, 150, 'worker slot_power_w overrides default factor';
    is $resolved->{hw_eur_per_slot_hour}, 0.05, 'worker hw_eur_per_slot_hour overrides default factor';
    is $resolved->{sources}->{slot_power_w}, 'worker', 'source recorded as worker for slot_power_w';
    is $resolved->{sources}->{hw_eur_per_slot_hour}, 'worker', 'source recorded as worker for hw_eur_per_slot_hour';
    is $resolved->{sources}->{cpu_w}, 'default', 'unspecified factor keeps default source';

    my $worker2 = $workers->find(2);
    my $resolved_default = resolve_factors(worker_props => $worker2->job_impact_factors);
    is $resolved_default->{slot_power_w}, '', 'worker without factors falls back to default slot_power_w';
    is $resolved_default->{sources}->{slot_power_w}, 'default', 'source recorded as default when worker has no factors';
};

done_testing();
