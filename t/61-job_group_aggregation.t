# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use OpenQA::App;
use OpenQA::BuildResults;
use Date::Format 'time2str';
use Feature::Compat::Try;
use Test::Mojo;

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $group_id = 1001;
my $group = $schema->resultset('JobGroups')->find($group_id);

subtest 'Aggregation with deduplication' => sub {
    my $version = 'agg_version';
    my $build = 'agg_build';
    my $t_created = time2str('%Y-%m-%d %H:%M:%S', time, 'UTC');
    my %common = (
        group_id => $group_id,
        priority => 50,
        state => 'done',
        TEST => 'test1',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        VERSION => $version,
        BUILD => $build,
        DISTRI => 'distri',
        t_created => $t_created,
        t_updated => $t_created,
    );
    # Create 3 jobs for the same scenario, only the latest (highest ID) should count
    my @jobs_data = (
        {%common, id => 300001, result => 'failed'},
        {%common, id => 300002, result => 'passed'},
        {%common, id => 300003, result => 'softfailed'},
    );
    $schema->resultset('Jobs')->populate(\@jobs_data);
    my $cbr = OpenQA::BuildResults::compute_build_results($group, 10, 0, undef, [], undef);
    my $build_res = (grep { $_->{key} eq "$version-$build" } @{$cbr->{build_results}})[0];
    ok $build_res, 'Found our build';
    is $build_res->{total}, 1, 'Deduplication works (3 jobs -> 1 result)';
    is $build_res->{softfailed}, 1, 'Takes the result of the latest job (id 300003)';
    is $build_res->{passed}, 0, 'Does not count older job (id 300002)';
    is $build_res->{failed}, 0, 'Does not count older job (id 300001)';
};

subtest 'Job limit enforcement' => sub {
    my $version = 'limit_version';
    my $build = 'limit_build';
    my $num_jobs = 5001;    # Exceeds DEFAULT_MAX_JOBS_PER_BUILD = 5000
    my $t_created = time2str('%Y-%m-%d %H:%M:%S', time, 'UTC');
    my %common = (
        group_id => $group_id,
        priority => 50,
        state => 'done',
        result => 'passed',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        VERSION => $version,
        BUILD => $build,
        DISTRI => 'distri',
        t_created => $t_created,
        t_updated => $t_created,
    );
    my @jobs_data;
    push @jobs_data, {%common, id => 400000 + $_, TEST => "test_$_"} for (1 .. $num_jobs);
    $schema->resultset('Jobs')->populate(\@jobs_data);
    my $error = '';
    try {
        OpenQA::BuildResults::compute_build_results($group, 10, 0, undef, [], undef);
    }
    catch ($e) {
        $error = $e;
    }
    like($error, qr/exceeds the limit of 5000/, 'Throws error when exceeding limit');
};

subtest 'Controller limit enforcement' => sub {
    my $version = 'ctrl_limit_version';
    my $build = 'ctrl_limit_build';
    my $num_jobs = 10;
    my $t_created = time2str('%Y-%m-%d %H:%M:%S', time, 'UTC');
    my %common = (
        group_id => $group_id,
        priority => 50,
        state => 'done',
        result => 'passed',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        VERSION => $version,
        BUILD => $build,
        DISTRI => 'distri',
        t_created => $t_created,
        t_updated => $t_created,
    );
    my @jobs_data;
    push @jobs_data, {%common, id => 500000 + $_, TEST => "test_$_"} for (1 .. $num_jobs);
    $schema->resultset('Jobs')->populate(\@jobs_data);
    # Set a very low limit in the app config
    $t->app->config->{misc_limits}->{job_group_overview_max_jobs} = 5;
    $t->get_ok("/group_overview/$group_id" => form => {distri => 'distri', version => $version, build => $build})
      ->status_is(400)->content_like(qr/exceeds the limit of 5/);
};

subtest 'API Controller limit enforcement' => sub {
    my $version = 'api_limit_version';
    my $build = 'api_limit_build';
    my $num_jobs = 10;
    my $t_created = time2str('%Y-%m-%d %H:%M:%S', time, 'UTC');
    my %common = (
        group_id => $group_id,
        priority => 50,
        state => 'done',
        result => 'passed',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        VERSION => $version,
        BUILD => $build,
        DISTRI => 'distri',
        t_created => $t_created,
        t_updated => $t_created,
    );
    my @jobs_data;
    push @jobs_data, {%common, id => 600000 + $_, TEST => "test_$_"} for (1 .. $num_jobs);
    $schema->resultset('Jobs')->populate(\@jobs_data);
    # Set a very low limit in the app config
    $t->app->config->{misc_limits}->{job_group_overview_max_jobs} = 5;
    $t->get_ok("/api/v1/job_groups/$group_id/build_results" => form => {limit_builds => 1, time_limit_days => 0})
      ->status_is(400)->content_like(qr/exceeds the limit of 5/);
};

done_testing;
