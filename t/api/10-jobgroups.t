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

subtest 'list' => sub() {
    my $get = $t->get_ok('/api/v1/job_groups')->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                'name'                           => 'opensuse',
                'parent_id'                      => undef,
                'sort_order'                     => undef,
                'keep_logs_in_days'              => 30,
                'keep_important_logs_in_days'    => 120,
                'default_priority'               => 50,
                'description'                    => undef,
                'keep_results_in_days'           => 365,
                'keep_important_results_in_days' => 0,
                'size_limit_gb'                  => 100,
                'id'                             => 1001
            },
            {
                'description'                    => undef,
                'keep_results_in_days'           => 365,
                'keep_important_results_in_days' => 0,
                'size_limit_gb'                  => 100,
                'id'                             => 1002,
                'name'                           => 'opensuse test',
                'parent_id'                      => undef,
                'keep_important_logs_in_days'    => 120,
                'sort_order'                     => undef,
                'keep_logs_in_days'              => 30,
                'default_priority'               => 50
            }]);
};

subtest 'update' => sub() {
    my $put = $t->put_ok(
        '/api/v1/job_groups/1001',
        form => {
            size_limit_gb               => 101,
            description                 => 'Test',
            keep_important_logs_in_days => 45
        });

    my $get = $t->get_ok('/api/v1/job_groups/1001')->status_is(200);
    is_deeply(
        $get->tx->res->json,
        [
            {
                'name'                           => 'opensuse',
                'parent_id'                      => undef,
                'sort_order'                     => undef,
                'keep_logs_in_days'              => 30,
                'keep_important_logs_in_days'    => 45,
                'default_priority'               => 50,
                'description'                    => 'Test',
                'keep_results_in_days'           => 365,
                'keep_important_results_in_days' => 0,
                'size_limit_gb'                  => 101,
                'id'                             => 1001
            },
        ]);
};

done_testing();
