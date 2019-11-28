# Copyright (C) 2016-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Mojo::JSON 'decode_json';

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema       = $app->schema;
my $audit_events = $schema->resultset('AuditEvents');

sub check_for_event {
    my ($event_name, $expectations) = @_;

    my @events     = $audit_events->search({event => $event_name}, {order_by => {-desc => 'id'}, rows => 1})->all;
    my $event      = $events[0];
    my $event_data = decode_json($event->event_data);
    is($event->user_id, 99901, 'user logged');
    if (my $group_name = $expectations->{group_name}) {
        is($event_data->{name}, $group_name, 'event data contains group name');
    }
    if (my $group_id = $expectations->{group_id}) {
        is($event_data->{id}, $group_id, 'event data contains group ID');
    }
}

subtest 'list job groups' => sub() {
    $t->get_ok('/api/v1/job_groups')->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name                           => 'opensuse',
                parent_id                      => undef,
                sort_order                     => 0,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 120,
                default_priority               => 50,
                carry_over_bugrefs             => 1,
                description                    => "## Test description\n\nwith bugref bsc#1234",
                template                       => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 100,
                build_version_sort             => 1,
                id                             => 1001,
                exclusively_kept_asset_size    => undef,
            },
            {
                description                    => undef,
                template                       => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 100,
                build_version_sort             => 1,
                id                             => 1002,
                name                           => 'opensuse test',
                parent_id                      => undef,
                keep_important_logs_in_days    => 120,
                sort_order                     => 0,
                keep_logs_in_days              => 30,
                default_priority               => 50,
                carry_over_bugrefs             => 1,
                exclusively_kept_asset_size    => undef,
            }]);
};

subtest 'create parent group' => sub() {
    $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name                                => 'Cool parent group',
            size_limit_gb                       => 200,
            default_keep_important_logs_in_days => 45
        })->status_is(200);
    my $new_id = $t->tx->res->json->{id};

    $t->get_ok('/api/v1/parent_groups/' . $new_id)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name                                   => 'Cool parent group',
                sort_order                             => undef,
                default_keep_logs_in_days              => 30,
                default_keep_important_logs_in_days    => 45,
                default_priority                       => 50,
                carry_over_bugrefs                     => 1,
                default_keep_results_in_days           => 365,
                default_keep_important_results_in_days => 0,
                size_limit_gb                          => 200,
                exclusively_kept_asset_size            => undef,
                id                                     => $new_id,
                description                            => undef,
                build_version_sort                     => 1,
            },
        ],
        'list created parent group'
    );

    check_for_event(jobgroup_create => {group_name => 'Cool parent group'});
};

subtest 'create job group' => sub() {
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name                        => 'Cool group',
            size_limit_gb               => 200,
            description                 => 'Test2',
            keep_important_logs_in_days => 45
        });
    my $new_id = $t->tx->res->json->{id};

    $t->get_ok('/api/v1/job_groups/' . $new_id)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name                           => 'Cool group',
                parent_id                      => undef,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 45,
                default_priority               => 50,
                carry_over_bugrefs             => 1,
                description                    => 'Test2',
                template                       => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 200,
                build_version_sort             => 1,
                id                             => $new_id,
                exclusively_kept_asset_size    => undef,
            },
        ],
        'list created job group'
    );

    $t->get_ok('/dashboard_build_results.json')->status_is(200);
    my $res = $t->tx->res->json;
    is(@{$res->{results}}, 2, 'empty job groups are not shown on index page');

    check_for_event(jobgroup_create => {group_name => 'Cool group'});
};

subtest 'update job group' => sub() {
    my $new_id = $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name                                   => 'Update parent',
            default_keep_important_logs_in_days    => 100,
            default_keep_important_results_in_days => 366
        })->tx->res->json->{id};

    $t->put_ok(
        '/api/v1/job_groups/1001',
        form => {
            name                        => 'opensuse',
            size_limit_gb               => 101,
            build_version_sort          => 0,
            description                 => 'Test',
            keep_important_logs_in_days => 45,
            parent_id                   => $new_id,
        });

    check_for_event(jobgroup_update => {group_name => 'opensuse'});

    $t->get_ok('/api/v1/job_groups/1001')->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name                           => 'opensuse',
                parent_id                      => $new_id,
                sort_order                     => 0,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 45,           # inherited value overridden
                default_priority               => 50,
                carry_over_bugrefs             => 1,
                description                    => 'Test',
                template                       => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 366,          # changed through inheritance
                size_limit_gb                  => 101,
                build_version_sort             => 0,
                id                             => 1001,
                exclusively_kept_asset_size    => undef,
            },
        ],
        'list updated job group'
    );
};

subtest 'delete job/parent group and error when listing non-existing group' => sub() {
    for my $variant (qw(job_groups parent_groups)) {
        $t->delete_ok("/api/v1/$variant/3498371")->status_is(404);
        my $new_id    = $t->post_ok("/api/v1/$variant", form => {name => 'To delete'})->tx->res->json->{id};
        my $delete_id = $t->delete_ok("/api/v1/$variant/$new_id")->status_is(200)->tx->res->json->{id};
        is($delete_id, $new_id, 'correct ID returned');
        check_for_event(jobgroup_delete => {group_id => $new_id});
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
    # Try to create a group has same name "Cool group" with existing one
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name      => 'Cool group',
            parent_id => undef,
        })->status_is(500);
    # Update "opensuse" group to have name "Cool group"
    $t->put_ok(
        '/api/v1/job_groups/1001',
        form => {
            name      => 'Cool group',
            parent_id => undef,
        })->status_is(500);
    # Update the existing "Cool group"
    $t->put_ok(
        '/api/v1/job_groups/1003',
        form => {
            name                        => 'Cool group',
            size_limit_gb               => 300,
            description                 => 'Updated group without parent',
            keep_important_logs_in_days => 100
        })->status_is(200);
    $t->get_ok('/api/v1/job_groups/1003')->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                name                           => 'Cool group',
                parent_id                      => undef,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 100,
                default_priority               => 50,
                carry_over_bugrefs             => 1,
                description                    => 'Updated group without parent',
                template                       => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 300,
                build_version_sort             => 1,
                id                             => 1003,
                exclusively_kept_asset_size    => undef,
            },
        ],
        'Update Cool group without parent'
    );
};

subtest 'prevent create parent/job group with empty or blank name' => sub() {
    for my $group (qw(parent_groups job_groups)) {
        for my $name (undef, '   ') {
            $t->post_ok("/api/v1/$group", form => {name => $name})->status_is(400);
            is(
                $t->tx->res->json->{error},
                'The group name must not be empty or blank',
                'Unable to create parent/job group with empty or blank name'
            );
        }
    }
};

subtest 'prevent update parent/job group with empty or blank name' => sub() {
    for my $name (undef, '   ') {
        $t->put_ok('/api/v1/parent_groups/1', form => {name => $name})->status_is(400);
        is(
            $t->tx->res->json->{error},
            'The group name must not be empty or blank',
            'Unable to update parent group with empty or blank name'
        );
    }
    for my $name (undef, '   ') {
        $t->put_ok('/api/v1/job_groups/1003', form => {name => $name})->status_is(400);
        is(
            $t->tx->res->json->{error},
            'The group name must not be empty or blank',
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
            name      => 'group1',
            parent_id => $parent_group_id
        })->status_is(200);
    $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name      => 'group1',
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
            name      => 'group2',
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
