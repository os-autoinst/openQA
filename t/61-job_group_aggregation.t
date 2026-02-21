# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockObject;
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
    my $t_created = time2str '%Y-%m-%d %H:%M:%S', time, 'UTC';
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
    # Create jobs for different categories, ensuring each is the latest for its scenario
    my @jobs_data = (
        {%common, id => 300001, result => 'failed', TEST => 'test_failed'},
        {%common, id => 300002, result => 'passed', TEST => 'test_passed'},
        {%common, id => 300003, result => 'softfailed', TEST => 'test_softfailed'},
        {%common, id => 300004, result => 'user_cancelled', TEST => 'test_aborted'},    # skipped (aborted)
        {%common, id => 300005, state => 'cancelled', result => 'none', TEST => 'test_cancelled'}, # skipped (cancelled)
        {%common, id => 300006, state => 'running', result => 'none', TEST => 'test_running'},    # unfinished
        {%common, id => 300007, result => 'passed', TEST => 'test_dedup'},
        {%common, id => 300008, result => 'softfailed', TEST => 'test_dedup'},    # latest for test_dedup
    );
    $schema->resultset('Jobs')->populate(\@jobs_data);
    my $cbr = OpenQA::BuildResults::compute_build_results($group, 10, 0, undef, [], undef);
    my $build_res = (grep { $_->{key} eq "$version-$build" } @{$cbr->{build_results}})[0];
    ok $build_res, 'Found our build';
    is $build_res->{total}, 7, 'Correct total (7 unique scenarios)';
    is $build_res->{passed}, 1, 'Counts passed';
    is $build_res->{failed}, 1, 'Counts failed';
    is $build_res->{softfailed}, 2, 'Counts softfailed (including deduped one)';
    is $build_res->{skipped}, 2, 'Counts both aborted and cancelled as skipped';
    is $build_res->{unfinished}, 1, 'Counts running job as unfinished';
};
subtest 'Direct count_job testing' => sub {
    my $jr = {};
    OpenQA::BuildResults::init_job_figures($jr);
    my $job_passed = Test::MockObject->new;
    $job_passed->set_always(id => 1)->set_always(state => 'done')->set_always(result => 'passed');
    OpenQA::BuildResults::count_job($job_passed, $jr, {});
    is $jr->{passed}, 1, 'count_job handles passed';
    my $job_failed = Test::MockObject->new;
    $job_failed->set_always(id => 2)->set_always(state => 'done')->set_always(result => 'failed');
    OpenQA::BuildResults::count_job($job_failed, $jr, {2 => {reviewed => 1, comments => 1}});
    is $jr->{failed}, 1, 'count_job handles failed';
    is $jr->{labeled}, 1, 'count_job handles labeled';
    is $jr->{comments}, 1, 'count_job handles comments';
    my $job_running = Test::MockObject->new;
    $job_running->set_always(id => 3)->set_always(state => 'running')->set_always(result => 'none');
    OpenQA::BuildResults::count_job($job_running, $jr, {});
    is $jr->{unfinished}, 1, 'count_job handles running as unfinished';
    # Test unknown state to hit log_error branch
    my $job_unknown = Test::MockObject->new;
    $job_unknown->set_always(id => 4)->set_always(state => 'unknown_state')->set_always(result => 'none');
    OpenQA::BuildResults::count_job($job_unknown, $jr, {});
    is $jr->{unfinished}, 2, 'count_job handles unknown state as unfinished';
};
subtest 'Parent group aggregation' => sub {
    my $parent = $schema->resultset('JobGroupParents')->create({name => 'parent', build_version_sort => 0});
    my $child1 = $schema->resultset('JobGroups')->create({name => 'child1', parent_id => $parent->id});
    my $child2 = $schema->resultset('JobGroups')->create({name => 'child2', parent_id => $parent->id});
    my $version = 'parent_version';
    my $build = 'parent_build';
    my %common = (
        priority => 50,
        state => 'done',
        result => 'passed',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        VERSION => $version,
        BUILD => $build,
        DISTRI => 'distri',
    );
    $schema->resultset('Jobs')->create({%common, id => 700001, group_id => $child1->id, TEST => 'test1'});
    $schema->resultset('Jobs')
      ->create({%common, id => 700002, group_id => $child2->id, TEST => 'test2', result => 'failed'});
    # Add a reviewed job
    $schema->resultset('Jobs')
      ->create({%common, id => 700003, group_id => $child2->id, TEST => 'test3', result => 'failed'});
    $schema->resultset('Comments')->create({job_id => 700003, text => 'label:acceptable', user_id => 99901});
    my $cbr = OpenQA::BuildResults::compute_build_results($parent, 10, 0, undef, [], undef);
    my $build_res = (grep { $_->{key} eq "$version-$build" } @{$cbr->{build_results}})[0];
    ok $build_res, 'Found our build in parent group';
    is $build_res->{total}, 3, 'Total for parent group is 3';
    is $build_res->{passed}, 1, 'One passed';
    is $build_res->{failed}, 2, 'Two failed';
    is $build_res->{labeled}, 1, 'One labeled';
    ok $build_res->{children}->{$child1->id}, 'Child 1 data present';
    is $build_res->{children}->{$child1->id}->{passed}, 1, 'Child 1 has 1 passed';
    ok $build_res->{children}->{$child2->id}, 'Child 2 data present';
    is $build_res->{children}->{$child2->id}->{failed}, 2, 'Child 2 has 2 failed';
    is $build_res->{children}->{$child2->id}->{labeled}, 1, 'Child 2 has 1 labeled';
};
subtest 'Tags mapping' => sub {
    my $version = 'tag_version';
    my $build = 'tag_build';
    my $key = "$version-$build";
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
    );
    $schema->resultset('Jobs')->create({%common, id => 800001, TEST => 'test1'});
    my $show_tags = {$key => {name => 'my_tag'}};
    my $cbr = OpenQA::BuildResults::compute_build_results($group, 10, 0, undef, [], $show_tags);
    my $build_res = (grep { $_->{key} eq $key } @{$cbr->{build_results}})[0];
    ok $build_res, 'Found our build for tags';
    is $build_res->{tag}->{name}, 'my_tag', 'Tag correctly mapped';
    # Test build-only tag fallback
    $show_tags = {$build => {name => 'build_tag'}};
    $cbr = OpenQA::BuildResults::compute_build_results($group, 10, 0, undef, [], $show_tags);
    $build_res = (grep { $_->{key} eq $key } @{$cbr->{build_results}})[0];
    is $build_res->{tag}->{name}, 'build_tag', 'Build-only tag correctly mapped';
};
subtest 'Filtering by tags' => sub {
    my %common = (
        group_id => $group_id,
        priority => 50,
        state => 'done',
        result => 'passed',
        ARCH => 'x86_64',
        FLAVOR => 'flavor',
        DISTRI => 'distri',
    );
    $schema->resultset('Jobs')->create({%common, id => 900001, VERSION => 'v1', BUILD => 'b1', TEST => 't1'});
    $schema->resultset('Jobs')->create({%common, id => 900002, VERSION => 'v2', BUILD => 'b2', TEST => 't1'});
    my $tags = {tag1 => {version => 'v1', build => 'b1'}};
    my $cbr = OpenQA::BuildResults::compute_build_results($group, 10, 0, $tags, [], undef);
    is scalar @{$cbr->{build_results}}, 1, 'Filtered to 1 build';
    is $cbr->{build_results}->[0]->{build}, 'b1', 'Correct build filtered';
};
subtest 'Job limit enforcement' => sub {
    my $version = 'limit_version';
    my $build = 'limit_build';
    my $num_jobs = 5001;    # Exceeds DEFAULT_MAX_JOBS_PER_BUILD = 5000
    my $t_created = time2str '%Y-%m-%d %H:%M:%S', time, 'UTC';
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
    like $error, qr/exceeds the limit of 5000/, 'Throws error when exceeding limit';
};
subtest 'Controller limit enforcement' => sub {
    my $group_id_ctrl = $schema->resultset('JobGroups')->create({name => 'ctrl_group'})->id;
    my $version = 'ctrl_limit_version';
    my $build = 'ctrl_limit_build';
    my $num_jobs = 10;
    my $t_created = time2str '%Y-%m-%d %H:%M:%S', time, 'UTC';
    my %common = (
        group_id => $group_id_ctrl,
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
    $t->get_ok("/group_overview/$group_id_ctrl" => form => {distri => 'distri', version => $version, build => $build})
      ->status_is(400)->content_like(qr/exceeds the limit of 5/);
};
subtest 'API Controller limit enforcement' => sub {
    my $group_id_api = $schema->resultset('JobGroups')->create({name => 'api_group'})->id;
    my $version = 'api_limit_version';
    my $build = 'api_limit_build';
    my $num_jobs = 10;
    my $t_created = time2str '%Y-%m-%d %H:%M:%S', time, 'UTC';
    my %common = (
        group_id => $group_id_api,
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
    $t->get_ok("/api/v1/job_groups/$group_id_api/build_results" => form => {limit_builds => 1, time_limit_days => 0})
      ->status_is(400)->content_like(qr/exceeds the limit of 5/);
};
done_testing;
