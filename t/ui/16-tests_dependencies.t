# Copyright (C) 2018 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::SeleniumTest;
use OpenQA::Schema::Result::JobDependencies;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub schema_hook {
    my $schema       = OpenQA::Test::Database->new->create;
    my $jobs         = $schema->resultset('Jobs');
    my $dependencies = $schema->resultset('JobDependencies');

    # make doc job a clone of the textmode job
    my $doc_job_id   = 99938;
    my $textmode_job = $jobs->find(99945);
    $textmode_job->update({clone_id => $doc_job_id});

    # insert dependencies to get:
    #             => textmode (99945)
    # kde (99937) => doc (99938)      => kde (99963)
    #                                    kde (99961)
    # (99963 and 99961 are a cluster/parallel)
    # (99945 is hidden because it is a clone of 99938)
    $dependencies->create(
        {
            child_job_id  => 99963,
            parent_job_id => 99938,
            dependency    => OpenQA::Schema::Result::JobDependencies::CHAINED,
        });
    $dependencies->create(
        {
            child_job_id  => 99945,
            parent_job_id => 99937,
            dependency    => OpenQA::Schema::Result::JobDependencies::CHAINED,
        });
}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

subtest 'dependency json' => sub {
    my $baseurl = $driver->get_current_url;
    my $t_api   = Test::Mojo->new;
    my $app     = $t_api->app;
    my $get;
    $t_api->ua(OpenQA::Client->new->ioloop(Mojo::IOLoop->singleton));
    $t_api->app($app);

    $get = $t->get_ok($baseurl . 'tests/99981/dependencies')->status_is(200)->json_is(
        undef => {
            cluster => {},
            edges   => [],
            nodes   => [
                {
                    blocked_by_id => undef,
                    id            => 99981,
                    label         => 'RAID0',
                    result        => 'skipped',
                    state         => 'cancelled',
                    tooltipText   => 'opensuse-13.1-GNOME-Live-i686-Build0091-RAID0@32bit',
                }]
        },
        'single node for job without dependencies'
    ) or diag explain $get->tx->res->json;

    $get = $t->get_ok($baseurl . 'tests/99938/dependencies')->status_is(200)->json_is(
        undef => {
            cluster => {
                cluster_99963 => [99963, 99961]
            },
            edges => [
                {
                    from => 99937,
                    to   => 99938,
                },
                {
                    from => 99938,
                    to   => 99963,
                }
            ],
            nodes => [
                {
                    blocked_by_id => undef,
                    id            => 99938,
                    label         => 'doc',
                    result        => 'failed',
                    state         => 'done',
                    tooltipText   => 'opensuse-Factory-DVD-x86_64-Build0048-doc@64bit',
                },
                {
                    blocked_by_id => undef,
                    id            => 99937,
                    label         => 'kde',
                    result        => 'passed',
                    state         => 'done',
                    tooltipText   => 'opensuse-13.1-DVD-i586-Build0091-kde@32bit',
                },
                {
                    blocked_by_id => undef,
                    id            => 99963,
                    label         => 'kde',
                    result        => 'none',
                    state         => 'running',
                    tooltipText   => 'opensuse-13.1-DVD-x86_64-Build0091-kde@64bit',
                },
                {
                    blocked_by_id => undef,
                    id            => 99961,
                    label         => 'kde',
                    result        => 'none',
                    state         => 'running',
                    tooltipText   => 'opensuse-13.1-NET-x86_64-Build0091-kde@64bit',
                }]
        },
        'nodes, edges and cluster computed'
    ) or diag explain $get->tx->res->json;
};

subtest 'job without dependencies' => sub {
    $driver->get('/tests/99981');
    my @dependencies_links = $driver->find_elements('Dependencies', 'link_text');
    is_deeply(\@dependencies_links, [], 'no dependency tab if no dependencies present');

    $driver->get('/tests/99945');
    @dependencies_links = $driver->find_elements('Dependencies', 'link_text');
    is_deeply(\@dependencies_links, [], 'no dependency tab if job has been cloned');
};

subtest 'graph rendering' => sub {
    $driver->get('/tests/99938');
    $driver->find_element_by_link_text('Dependencies')->click();
    wait_for_ajax();
    javascript_console_has_no_warnings_or_errors();

    my $graph                  = $driver->find_element_by_id('dependencygraph');
    my $check_element_quandity = sub {
        my ($selector, $expected_count, $test_name) = @_;
        my @child_elements = $driver->find_child_elements($graph, $selector);
        is(scalar @child_elements, $expected_count, $test_name);
    };
    $check_element_quandity->('.cluster',  1, 'one cluster present');
    $check_element_quandity->('.edgePath', 2, 'two edges present');
    $check_element_quandity->('.node',     4, 'four nodes present');
};

kill_driver();
done_testing();
