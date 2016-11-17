# Copyright (C) 2016 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

subtest 'list job groups' => sub() {
    my $get = $t->get_ok('/api/v1/job_groups')->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                name                           => 'opensuse',
                parent_id                      => undef,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 120,
                default_priority               => 50,
                description                    => '##Test description\n\nwith bugref bsc#1234',
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 100,
                id                             => 1001
            },
            {
                description                    => undef,
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 100,
                id                             => 1002,
                name                           => 'opensuse test',
                parent_id                      => undef,
                keep_important_logs_in_days    => 120,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                default_priority               => 50
            }]);
};

subtest 'create parent group' => sub() {
    my $post = $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name                                => 'Cool parent group',
            default_size_limit_gb               => 200,
            default_keep_important_logs_in_days => 45
        })->status_is(200);
    my $new_id = $post->tx->res->json->{id};

    my $get = $t->get_ok('/api/v1/parent_groups/' . $new_id)->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                name                                   => 'Cool parent group',
                sort_order                             => undef,
                default_keep_logs_in_days              => 30,
                default_keep_important_logs_in_days    => 45,
                default_priority                       => 50,
                default_keep_results_in_days           => 365,
                default_keep_important_results_in_days => 0,
                default_size_limit_gb                  => 200,
                id                                     => $new_id,
                description                            => undef,
            },
        ],
        'list created parent group'
    );
};

subtest 'create job group' => sub() {
    my $post = $t->post_ok(
        '/api/v1/job_groups',
        form => {
            name                        => 'Cool group',
            size_limit_gb               => 200,
            description                 => 'Test2',
            keep_important_logs_in_days => 45
        });
    my $new_id = $post->tx->res->json->{id};

    my $get = $t->get_ok('/api/v1/job_groups/' . $new_id)->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                name                           => 'Cool group',
                parent_id                      => undef,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 45,
                default_priority               => 50,
                description                    => 'Test2',
                keep_results_in_days           => 365,
                keep_important_results_in_days => 0,
                size_limit_gb                  => 200,
                id                             => $new_id
            },
        ],
        'list created job group'
    );

    $get = $t->get_ok('/index.json')->status_is(200);
    $get = $get->tx->res->json;
    is(@{$get->{results}}, 2, 'empty job groups are not shown on index page');
};

subtest 'update job group' => sub() {
    my $new_id = $t->post_ok(
        '/api/v1/parent_groups',
        form => {
            name                                   => 'Update parent',
            default_keep_important_logs_in_days    => 100,
            default_keep_important_results_in_days => 366
        })->tx->res->json->{id};

    my $put = $t->put_ok(
        '/api/v1/job_groups/1001',
        form => {
            size_limit_gb               => 101,
            description                 => 'Test',
            keep_important_logs_in_days => 45,
            parent_id                   => $new_id,
        });

    my $get = $t->get_ok('/api/v1/job_groups/1001')->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                name                           => 'opensuse',
                parent_id                      => $new_id,
                sort_order                     => undef,
                keep_logs_in_days              => 30,
                keep_important_logs_in_days    => 45,           # inherited value overridden
                default_priority               => 50,
                description                    => 'Test',
                keep_results_in_days           => 365,
                keep_important_results_in_days => 366,          # changed through inheritance
                size_limit_gb                  => 101,
                id                             => 1001,
            },
        ],
        'list updated job group'
    );
};

subtest 'delete job/parent group and error when listing non-existing group' => sub() {
    for my $variant (qw(job_groups parent_groups)) {
        $t->delete_ok("/api/v1/$variant/3498371")->status_is(404);
        my $new_id = $t->post_ok("/api/v1/$variant", form => {name => 'To delete'})->tx->res->json->{id};
        my $delete = $t->delete_ok("/api/v1/$variant/$new_id")->status_is(200);
        is($delete->tx->res->json->{id}, $new_id, 'correct ID returned');
        my $get = $t->get_ok("/api/v1/$variant/$new_id")->status_is(404);
        is_deeply($get->tx->res->json, {error => "Group $new_id does not exist"}, 'error about non-existing group');
    }
};

subtest 'prevent deleting non-empty job group' => sub() {
    my $delete = $t->delete_ok('/api/v1/job_groups/1002')->status_is(400);
    is_deeply($delete->tx->res->json, {error => 'Job group 1002 is not empty'});
    my $get = $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(200);
    is_deeply($get->tx->res->json, {ids => [99961]}, '1002 contains one job');
    $get = $t->get_ok('/api/v1/job_groups/1002/jobs?expired=1')->status_is(200);
    is_deeply($get->tx->res->json, {ids => []}, '1002 contains no expired job');
    my $rd = 't/data/openqa/testresults/00099/00099961-opensuse-13.1-DVD-x86_64-Build0091-kde';
    ok(-d $rd, 'result dir of job exists');
    $t->delete_ok('/api/v1/jobs/99961')->status_is(200);
    ok(!-d $rd, 'result dir of job gone');
    $get = $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(200);
    is_deeply($get->tx->res->json, {ids => []}, '1002 contains no more jobs');
    $t->delete_ok('/api/v1/job_groups/1002')->status_is(200);
    $get = $t->get_ok('/api/v1/job_groups/1002/jobs')->status_is(404);
};

done_testing();
