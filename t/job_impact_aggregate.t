# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use utf8;
use Mojo::Base -signatures;
use Test::Mojo;
use DateTime;

use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $jobs = $schema->resultset('Jobs');
my $impacts = $schema->resultset('JobImpacts');

subtest 'JobImpacts resultset aggregate and latency' => sub {
    my $group_id = 1001;
    my $now = DateTime->now(time_zone => 'UTC');
    my $earlier = $now->clone->subtract(hours => 2);

    # Create original job
    my $orig_finished = $earlier->clone->add(minutes => 30);
    my $clone_finished = $now->clone->add(hours => 1);
    my $orig = $jobs->create(
        {
            group_id => $group_id,
            TEST => 'agg_test_orig',
            DISTRI => 'opensuse',
            VERSION => '15.4',
            FLAVOR => 'DVD',
            ARCH => 'x86_64',
            MACHINE => '64bit',
            BUILD => '1000',
            state => DONE,
            result => FAILED,
            t_started => $earlier,
            t_finished => $orig_finished,
        });
    $orig->create_related(
        'impact',
        {
            seconds => 1800,
            vcpus => 2,
            ram_gb => 4,
            power_w => 50,
            energy_kwh => 0.0375,
            carbon_g => 12.5,
            cost_energy => 0.0075,
            cost_hardware => 0.005,
            cost_total => 0.0125,
            currency => 'EUR',
            model_version => 1,
            factors => {},
        });

    # Create user restart clone
    my $user_clone = $jobs->create(
        {
            group_id => $group_id,
            TEST => 'agg_test_clone_user',
            DISTRI => 'opensuse',
            VERSION => '15.4',
            FLAVOR => 'DVD',
            ARCH => 'x86_64',
            MACHINE => '64bit',
            BUILD => '1000',
            state => DONE,
            result => PASSED,
            restart_origin => RESTART_ORIGIN_USER,
            t_started => $earlier->clone->add(hours => 1),
            t_finished => $clone_finished,
        });
    $orig->update({clone_id => $user_clone->id, t_finished => $orig_finished});
    $user_clone->create_related(
        'impact',
        {
            seconds => 1800,
            vcpus => 2,
            ram_gb => 4,
            power_w => 50,
            energy_kwh => 0.0375,
            carbon_g => 12.5,
            cost_energy => 0.0075,
            cost_hardware => 0.005,
            cost_total => 0.0125,
            currency => 'EUR',
            model_version => 1,
            factors => {},
        });

    # Test aggregate
    my $agg = $impacts->aggregate(group_id => $group_id, build => '1000');
    ok $agg, 'returns aggregation result';
    is $agg->{total}->{jobs}, 2, 'aggregates total 2 jobs';
    is $agg->{total}->{seconds}, 3600, 'total seconds is 3600';
    is $agg->{total}->{cost_total}, 0.025, 'total cost is 0.025';

    is $agg->{by_origin}->{first_run}->{jobs}, 1, 'first_run job count is 1';
    is $agg->{by_origin}->{user}->{jobs}, 1, 'user restart job count is 1';
    is $agg->{by_origin}->{retry}->{jobs}, 0, 'retry job count is 0';

    # Test latency
    my $latency = $impacts->added_latency(group_id => $group_id, build => '1000');
    ok $latency, 'returns latency result';
    ok $latency->{user} > 0, 'user restart added latency > 0 hours';
    is $latency->{retry}, 0, 'retry latency is 0 when no retry';

    # Empty filter test
    my $empty_agg = $impacts->aggregate(group_id => 999999);
    is $empty_agg->{total}->{jobs}, 0, 'empty filter returns 0 jobs';
    is $empty_agg->{total}->{cost_total}, 0, 'empty filter returns 0 cost';
};

subtest 'Job impact API aggregation endpoints' => sub {
    $t->get_ok('/api/v1/job_groups/1001/impact')->status_is(200);
    my $res = $t->tx->res->json;
    is $res->{group_id}, 1001, 'returns correct group_id';
    ok exists $res->{total}, 'contains total object';
    ok exists $res->{by_origin}, 'contains by_origin object';
    ok exists $res->{added_latency_hours}, 'contains added_latency_hours object';

    $t->get_ok('/api/v1/job_groups/9999999/impact')->status_is(404);

    $t->get_ok('/api/v1/impact?build=1000')->status_is(200);
    my $overview_res = $t->tx->res->json;
    ok exists $overview_res->{total}, 'overview contains total object';
    ok exists $overview_res->{by_origin}, 'overview contains by_origin object';
};

done_testing;
