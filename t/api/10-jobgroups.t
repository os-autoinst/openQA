# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Test::Client;
use Mojo::IOLoop;
use Mojo::JSON 'decode_json';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'), apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');
my $schema = $t->app->schema;
my $audit_events = $schema->resultset('AuditEvents');

my $opensuse_group = '1001';
subtest 'list job groups' => sub() {
    $t->get_ok('/api/v1/job_groups')->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name => 'opensuse',
                parent_id => undef,
                sort_order => 0,
                keep_logs_in_days => 30,
                keep_important_logs_in_days => 120,
                default_priority => 50,
                carry_over_bugrefs => 1,
                description => "## Test description\n\nwith bugref bsc#1234",
                template => undef,
                keep_results_in_days => 365,
                keep_important_results_in_days => 0,
                size_limit_gb => 100,
                build_version_sort => 1,
                id => $opensuse_group,
                exclusively_kept_asset_size => undef,
            },
            {
                description => undef,
                template => undef,
                keep_results_in_days => 365,
                keep_important_results_in_days => 0,
                size_limit_gb => 100,
                build_version_sort => 1,
                id => 1002,
                name => 'opensuse test',
                parent_id => undef,
                keep_important_logs_in_days => 120,
                sort_order => 0,
                keep_logs_in_days => 30,
                default_priority => 50,
                carry_over_bugrefs => 1,
                exclusively_kept_asset_size => undef,
            }]);
};

subtest 'create parent group' => sub() {
    my @forms = (
        {size_limit_gb => '-300GB'},
        {build_version_sort => 'true'},
        {keep_logs_in_days => '18 days'},
        {keep_important_logs_in_days => '4 days'},
        {keep_results_in_days => '30 days'},
        {keep_important_results_in_days => '1 days'},
        {default_priority => 'inherit'},
        {carry_over_bugrefs => 'no'},
    );
    for my $form (@forms) {
        my $parameter = (keys %$form)[0];
        $form->{name} = 'Cool parent group';
        $t->post_ok('/api/v1/parent_groups', form => $form)->status_is(400, "Create group with invalid $parameter")
          ->json_is(
            '/error' => "Erroneous parameters ($parameter invalid)",
            'Invalid parameter types caught'
          );
        return diag explain $t->tx->res->json unless $t->success;
    }

    $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name => 'Cool parent group',
            size_limit_gb => 200,
            default_keep_important_logs_in_days => 45
        })->status_is(200);
    return diag explain $t->tx->res->json unless $t->success;

    my $new_id = $t->tx->res->json->{id};
    $t->get_ok('/api/v1/parent_groups/' . $new_id)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name => 'Cool parent group',
                sort_order => undef,
                default_keep_logs_in_days => 30,
                default_keep_important_logs_in_days => 45,
                default_priority => 50,
                carry_over_bugrefs => 1,
                default_keep_results_in_days => 365,
                default_keep_important_results_in_days => 0,
                size_limit_gb => 200,
                exclusively_kept_asset_size => undef,
                id => $new_id,
                description => undef,
                build_version_sort => 1,
            },
        ],
        'list created parent group'
    );

    my $event = OpenQA::Test::Case::find_most_recent_event($schema, 'jobgroup_create');
    is($event->{id}, $new_id, 'event contains parent group id');
};

my $cool_group_id;
subtest 'create job group' => sub() {
    my @forms = (
        {size_limit_gb => '-300GB'},
        {build_version_sort => 'true'},
        {keep_logs_in_days => '18 days'},
        {keep_important_logs_in_days => '4 days'},
        {keep_results_in_days => '30 days'},
        {keep_important_results_in_days => '1 days'},
        {default_priority => 'inherit'},
        {carry_over_bugrefs => 'no'},
    );
    for my $form (@forms) {
        my $parameter = (keys %$form)[0];
        $form->{name} = 'Cold group';
        $t->post_ok('/api/v1/job_groups', form => $form)->status_is(400, "Create group with invalid $parameter")
          ->json_is(
            '/error' => "Erroneous parameters ($parameter invalid)",
            'Invalid parameter types caught'
          );
        return diag explain $t->tx->res->json unless $t->success;
    }

    @forms = (
        {name => 'Foobar', description => ''},
        {name => 'Spam', description => 'Test2'},
        {name => 'Eggs', size_limit_gb => ''},
        {name => 'Foo', size_limit_gb => 200},
        {name => 'Bar', keep_important_logs_in_days => 45},
        {name => 'Cool group', size_limit_gb => 200, description => 'Test2', keep_important_logs_in_days => 45},
    );
    for my $form (@forms) {
        $t->post_ok('/api/v1/job_groups', form => $form)
          ->status_is(200, "Create group $form->{name} with different properties");
        return diag explain $t->tx->res->json unless $t->success;
    }

    $cool_group_id = $t->tx->res->json->{id};
    $t->get_ok('/api/v1/job_groups/' . $cool_group_id)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name => 'Cool group',
                parent_id => undef,
                sort_order => undef,
                keep_logs_in_days => 30,
                keep_important_logs_in_days => 45,
                default_priority => 50,
                carry_over_bugrefs => 1,
                description => 'Test2',
                template => undef,
                keep_results_in_days => 365,
                keep_important_results_in_days => 0,
                size_limit_gb => 200,
                build_version_sort => 1,
                id => $cool_group_id,
                exclusively_kept_asset_size => undef,
            },
        ],
        'list created job group'
    );

    $t->get_ok('/dashboard_build_results.json')->status_is(200);
    my $res = $t->tx->res->json;
    is(@{$res->{results}}, 2, 'empty job groups are not shown on index page');

    my $event = OpenQA::Test::Case::find_most_recent_event($schema, 'jobgroup_create');
    is($event->{id}, $cool_group_id, 'event contains group id');
};

subtest 'update job group' => sub() {
    my $new_id = $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name => 'Update parent',
            default_keep_logs_in_days => 22,
            default_keep_important_logs_in_days => 44,
            default_keep_results_in_days => 222,
            default_keep_important_results_in_days => 333
        })->tx->res->json->{id};
    return diag explain $t->tx->res->json unless $t->success;

    my @forms = (
        {size_limit_gb => '-300GB'},
        {build_version_sort => 'true'},
        {keep_logs_in_days => '18 days'},
        {keep_important_logs_in_days => '4 days'},
        {keep_results_in_days => '30 days'},
        {keep_important_results_in_days => '1 days'},
        {default_priority => 'inherit'},
        {carry_over_bugrefs => 'no'},
        {drag => 'maybe'},
    );
    for my $form (@forms) {
        my $parameter = (keys %$form)[0];
        $form->{name} = 'Cold group';
        $t->put_ok("/api/v1/job_groups/$opensuse_group", form => $form)
          ->status_is(400, "Update group with invalid $parameter")->json_is(
            '/error' => "Erroneous parameters ($parameter invalid)",
            'Invalid parameter types caught'
          );
        return diag explain $t->tx->res->json unless $t->success;
    }

    $t->put_ok(
        "/api/v1/job_groups/$opensuse_group",
        form => {
            name => 'opensuse',
            size_limit_gb => 101,
            build_version_sort => 0,
            default_priority => 70,
            description => 'Test',
            carry_over_bugrefs => 0,
            parent_id => $new_id,
        })->status_is(200);

    my $event = OpenQA::Test::Case::find_most_recent_event($schema, 'jobgroup_update');
    is($event->{id}, $opensuse_group, 'event contains group id');

    $t->put_ok(
        "/api/v1/job_groups/$opensuse_group",
        form => {
            drag => 1,
            sort_order => 123,
            parent_id => $new_id,
        })->status_is(200, 'Name is optional if drag is specified');
    return diag explain $t->tx->res->json unless $t->success;

    $t->get_ok("/api/v1/job_groups/$opensuse_group")->status_is(200);
    $t->json_is('/0/keep_logs_in_days' => 22, 'inherited logs expiry from parent');
    $t->json_is('/0/keep_important_logs_in_days' => 44, 'inherited important logs expiry from parent');
    $t->json_is('/0/keep_results_in_days' => 222, 'inherited results expiry from parent');
    $t->json_is('/0/keep_important_results_in_days' => 333, 'inherited important results expiry from parent');
    $t->json_is('/0/sort_order' => 123, 'sort order updated');

    $t->put_ok(
        "/api/v1/job_groups/$opensuse_group",
        form => {
            name => 'opensuse',
            keep_logs_in_days => 20,
            keep_important_logs_in_days => 40,
            keep_results_in_days => 200,
            keep_important_results_in_days => 300,
        })->status_is(200, 'defaults overridden');

    $t->get_ok("/api/v1/job_groups/$opensuse_group")->status_is(200);
    $t->json_is('/0/keep_logs_in_days' => 20, 'inherited logs expiry overridden');
    $t->json_is('/0/keep_important_logs_in_days' => 40, 'inherited important logs expiry overridden');
    $t->json_is('/0/keep_results_in_days' => 200, 'inherited results expiry overridden');
    $t->json_is('/0/keep_important_results_in_days' => 300, 'inherited important results expiry overridden');
};

subtest 'delete job/parent group and error when listing non-existing group' => sub() {
    for my $variant (qw(job_groups parent_groups)) {
        $t->delete_ok("/api/v1/$variant/3498371")->status_is(404);
        my $new_id = $t->post_ok("/api/v1/$variant", form => {name => 'To delete'})->tx->res->json->{id};
        my $delete_id = $t->delete_ok("/api/v1/$variant/$new_id")->status_is(200)->tx->res->json->{id};
        is($delete_id, $new_id, 'correct ID returned');
        my $event = OpenQA::Test::Case::find_most_recent_event($schema, 'jobgroup_delete');
        is($event->{id}, $new_id, 'event contains id');
        $t->get_ok("/api/v1/$variant/$new_id")->status_is(404);
        is_deeply(
            $t->tx->res->json,
            {error => "Group $new_id does not exist", error_status => 404},
            'error about non-existing group'
        );
    }
};

subtest 'prevent deleting non-empty job group' => sub() {
    $t->delete_ok('/api/v1/job_groups/1002')->status_is(400);
    is_deeply($t->tx->res->json, {error => 'Job group 1002 is not empty', error_status => 400});
    $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(200);
    is_deeply($t->tx->res->json, {ids => [99961]}, '1002 contains one job');
    $t->get_ok('/api/v1/job_groups/1002/jobs?expired=1')->status_is(200);
    is_deeply($t->tx->res->json, {ids => []}, '1002 contains no expired job');
    my $rd = 't/data/openqa/testresults/00099/00099961-opensuse-13.1-DVD-x86_64-Build0091-kde';
    ok(-d $rd, 'result dir of job exists');
    $t->delete_ok('/api/v1/jobs/99961')->status_is(200);
    ok(!-d $rd, 'result dir of job gone');
    $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(200);
    is_deeply($t->tx->res->json, {ids => []}, '1002 contains no more jobs');
    $t->delete_ok('/api/v1/job_groups/1002')->status_is(200);
    $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(404);
};

subtest 'prevent create/update duplicate job group on top level' => sub() {
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name => 'Cool group',
            parent_id => undef,
        })->status_is(500, 'Creating new group with existing name is an error');
    $t->put_ok(
        "/api/v1/job_groups/$opensuse_group",
        form => {
            name => 'Cool group',
            parent_id => undef,
        })->status_is(500, 'Renaming group with existing name is an error');
    $t->put_ok(
        "/api/v1/job_groups/$cool_group_id",
        form => {
            name => 'Cool group',
            size_limit_gb => 300,
            description => 'Updated group without parent',
            keep_important_logs_in_days => 100
        })->status_is(200, 'Update existing group without parent');
    $t->get_ok("/api/v1/job_groups/$cool_group_id")->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name => 'Cool group',
                parent_id => undef,
                sort_order => undef,
                keep_logs_in_days => 30,
                keep_important_logs_in_days => 100,
                default_priority => 50,
                carry_over_bugrefs => 1,
                description => 'Updated group without parent',
                template => undef,
                keep_results_in_days => 365,
                keep_important_results_in_days => 0,
                size_limit_gb => 300,
                build_version_sort => 1,
                id => $cool_group_id,
                exclusively_kept_asset_size => undef,
            },
        ],
        'Update Cool group without parent'
    );
};

subtest 'prevent create parent/job group with empty or blank name' => sub() {
    for my $group (qw(parent_groups job_groups)) {
        my %tests = (missing => undef, invalid => '   ');
        foreach my $error (sort keys %tests) {
            my $name = $tests{$error};
            $t->post_ok("/api/v1/$group", form => {name => $name})->status_is(400)->json_is(
                '/error' => "Erroneous parameters (name $error)",
                'Unable to create job group with empty or blank name'
            );
        }
    }
};

subtest 'prevent update parent/job group with empty or blank name' => sub() {
    my %tests = (missing => undef, invalid => '   ');
    foreach my $error (sort keys %tests) {
        my $name = $tests{$error};
        $t->put_ok('/api/v1/parent_groups/1', form => {name => $name})->status_is(400)->json_is(
            '/error' => "Erroneous parameters (name $error)",
            'Unable to update parent group with empty or blank name'
        );
        $t->put_ok("/api/v1/job_groups/$cool_group_id", form => {name => $name})->status_is(400)->json_is(
            '/error' => "Erroneous parameters (name $error)",
            'Unable to update job group with empty or blank name'
        );
    }
};

subtest 'prevent create/update duplicate job group on same parent group' => sub() {
    my $parent_group_id = $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name => 'parent_group',
        })->tx->res->json->{id};
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name => 'group1',
            parent_id => $parent_group_id
        })->status_is(200);
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name => 'group1',
            parent_id => $parent_group_id
        })->status_is(400);
    like(
        $t->tx->res->json->{error},
        qr/duplicate key/,
        'Unable to create group due to not allow duplicated job group on the same parent job group'
    );
    my $group2_id = $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name => 'group2',
            parent_id => $parent_group_id
        })->tx->res->json->{id};
    $t->put_ok(
        "/api/v1/job_groups/$group2_id",
        form => {
            name => 'group1',
        })->status_is(400);
    like(
        $t->tx->res->json->{error},
        qr/duplicate key/,
        'Unable to update group due to not allow duplicated job group on the same parent job group'
    );
};

done_testing();
