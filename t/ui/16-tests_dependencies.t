# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN { $ENV{OPENQA_DEPENDENCY_DEBUG_INFO} = 1 }

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::SeleniumTest;
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::JobDependencies::Constants qw(CHAINED DIRECTLY_CHAINED PARALLEL);
use OpenQA::Jobs::Constants;
use OpenQA::WebAPI::Controller::Test;

subtest 'detailed behavior of merging parallel jobs into clusters' => sub {
    my (%clusters, %cluster_by_job);
    my %data = (cluster => \%clusters, cluster_by_job => \%cluster_by_job);
    my $add_parallel_dependency = sub ($parent_job_id, $child_job_id) {
        OpenQA::WebAPI::Controller::Test::_add_dependency_to_graph(\%data, $parent_job_id, $child_job_id, PARALLEL);
    };

    $add_parallel_dependency->(1, 2);
    is_deeply \%clusters, {cluster_2 => [2, 1]}, 'new cluster created';

    $add_parallel_dependency->(3, 4);
    is_deeply \%clusters, {cluster_2 => [2, 1], cluster_4 => [4, 3]}, 'another distinct cluster created';
    is_deeply \%cluster_by_job, {1 => 'cluster_2', 2 => 'cluster_2', 3 => 'cluster_4', 4 => 'cluster_4'},
      'clusters tracked by job';

    $add_parallel_dependency->(3, 5);
    is_deeply \%clusters, {cluster_2 => [2, 1], cluster_4 => [4, 3, 5]}, 'child added into existing cluster';

    $add_parallel_dependency->(6, 5);
    is_deeply \%clusters, {cluster_2 => [2, 1], cluster_4 => [4, 3, 5, 6]}, 'parent added into existing cluster';

    $add_parallel_dependency->(3, 5);
    is_deeply \%clusters, {cluster_2 => [2, 1], cluster_4 => [4, 3, 5, 6]}, 'no change if jobs already in same cluster';

    $add_parallel_dependency->(6, 1);
    is_deeply \%clusters, {cluster_2 => [2, 1, 4, 3, 5, 6]}, 'the two existing clusters were merged';
    is_deeply \%cluster_by_job, {map { $_ => 'cluster_2' } 1 .. 6}, 'all jobs in one cluster after merge';
};

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 05-job_modules.pl 06-job_dependencies.pl'
);

my $jobs = $schema->resultset('Jobs');
my $dependencies = $schema->resultset('JobDependencies');

# make doc job a clone of the textmode job
my $doc_job_id = 99938;
my $textmode_job = $jobs->find(99945);
$textmode_job->update({clone_id => $doc_job_id});

# avoid duplicating the chained parent 99938 for the sake of this test
$jobs->find(99938)->update({result => PASSED});

# insert dependencies (in addition to existing ones in regular fixtures) to get the following graph:
#             => textmode (99945)
# kde (99937) => doc (99938)      => kde (99963)
#                                    kde (99961) => RAID0 (99927)
# (99963 and 99961 are a cluster/parallel)
# (99945 is hidden because it is a clone of 99938)
# (99927 follows 99961 *directly*)
# note: This cluster makes no sense but that is not the point of this test.
$dependencies->create({child_job_id => 99963, parent_job_id => 99938, dependency => CHAINED});
$dependencies->create({child_job_id => 99945, parent_job_id => 99937, dependency => CHAINED});
$dependencies->create({child_job_id => 99927, parent_job_id => 99961, dependency => DIRECTLY_CHAINED});

my $t = Test::Mojo->new('OpenQA::WebAPI');
driver_missing unless my $driver = call_driver;

sub get_tooltip ($job_id) {
    $driver->execute_script("return \$('#nodeTable$job_id').closest('.node').data('bs-original-title');");
}

sub node_name ($name, $a, $d, $as_child, $pd) {
    "opensuse-$name (ancestors: $a, descendants: $d, as child: $as_child, preferred depth: $pd)";
}

subtest 'dependency json' => sub {
    my $baseurl = $driver->get_current_url;
    my (%cluster, @edges);
    my @basic_node = (blocked_by_id => undef, chained => [], directly_chained => [], parallel => []);
    my @nodes = (
        {
            @basic_node,
            id => 99981,
            label => 'RAID0@32bit',
            result => SKIPPED,
            state => CANCELLED,
            name => node_name('13.1-GNOME-Live-i686-Build0091-RAID0@32bit', 0, 0, 0, 0),
        });
    my %expected = (cluster => \%cluster, edges => \@edges, nodes => \@nodes);
    $t->get_ok($baseurl . 'tests/99981/dependencies_ajax')->status_is(200);
    $t->json_is('' => \%expected, 'single node for job without dependencies');
    always_explain $t->tx->res->json unless $t->success;

    %cluster = (cluster_99963 => [99963, 99961]);
    @edges = ({from => 99937, to => 99938}, {from => 99961, to => 99927}, {from => 99938, to => 99963});
    @nodes = (
        {
            @basic_node,
            id => 99938,
            label => 'doc@64bit',
            result => PASSED,
            state => DONE,
            name => node_name('Factory-DVD-x86_64-Build0048-doc@64bit', 2, 0, 0, 2),
            chained => ['kde'],
        },
        {
            @basic_node,
            id => 99937,
            label => 'kde@32bit',
            result => PASSED,
            state => DONE,
            name => node_name('13.1-DVD-i586-Build0091-kde@32bit', 0, 0, 0, 2),
        },
        {
            @basic_node,
            id => 99963,
            label => 'kde@64bit',
            result => NONE,
            state => RUNNING,
            name => node_name('13.1-DVD-x86_64-Build0091-kde@64bit', 1, 0, 99938, 2),
            chained => ['doc'],
            parallel => ['kde'],
        },
        {
            @basic_node,
            id => 99961,
            label => 'kde@64bit',
            result => NONE,
            state => RUNNING,
            name => node_name('13.1-NET-x86_64-Build0091-kde@64bit', 0, 0, 99938, 2),
        },
        {
            @basic_node,
            id => 99927,
            label => 'RAID0@32bit',
            result => NONE,
            state => SCHEDULED,
            name => node_name('13.1-DVD-i586-Build0091-RAID0@32bit', 0, 0, 99961, 2),
            directly_chained => ['kde'],
        });
    $t->get_ok($baseurl . 'tests/99938/dependencies_ajax')->status_is(200);
    $t->json_is('' => \%expected, 'nodes, edges and cluster computed');
    always_explain $t->tx->res->json unless $t->success;
};

subtest 'dependency JSON after duplicating jobs' => sub {
    # remove the job 99938 is cloned as to make this test more distinct from the previous subtest
    $schema->txn_begin;
    $textmode_job->delete;

    # duplicate one of the jobs in the parallel cluster (which will also duplicate a few dependend jobs)
    my $duplicates = $jobs->find(99963)->auto_duplicate->{cluster_cloned};
    my @new_jobs = sort values %$duplicates;
    my $directly_chained_child_dup = $duplicates->{99927};
    is_deeply [sort keys %$duplicates], [99927, 99961, 99963], 'expected set of jobs has been duplicated';

    subtest 'graph for the original jobs' => sub {
        my $json = $t->get_ok('/tests/99963/dependencies_ajax')->status_is(200)->tx->res->json;
        my @rendered_nodes = sort map { $_->{id} } @{$json->{nodes}};
        my @expected_nodes = (
            99927,    # because it has the same clone-depth as the original job
            99937,    # because it has not been duplicated
            99938,    # because it has not been duplicated
            99961,    # because it has the same clone-depth as the original job
            99963,    # because it is the original job
            @new_jobs    # because those are indirect dependencies
        );
        is_deeply \@rendered_nodes, \@expected_nodes, 'all original jobs are present as well'
          or always_explain \@rendered_nodes, $duplicates;

        $json = $t->get_ok('/tests/99961/dependencies_ajax')->status_is(200)->tx->res->json;
        @rendered_nodes = sort map { $_->{id} } @{$json->{nodes}};
        @expected_nodes = grep { $_ != $directly_chained_child_dup } @expected_nodes;
        is_deeply \@rendered_nodes, \@expected_nodes,
          'same outcome for parallel sibling except that directly chained child is not indirectly added'
          or always_explain \@rendered_nodes, $duplicates;
    };

    subtest 'graph for the duplicated jobs' => sub {
        my $json = $t->get_ok("/tests/$duplicates->{99963}/dependencies_ajax")->status_is(200)->tx->res->json;
        my @rendered_nodes = sort map { $_->{id} } @{$json->{nodes}};
        my @expected_nodes = (
            99937,    # because it has not been duplicated
            99938,    # because it has not been duplicated
            @new_jobs    # because those are the duplicated jobs
        );
        is_deeply \@rendered_nodes, \@expected_nodes, 'only the latest jobs are shown'
          or always_explain \@rendered_nodes;
    };

    $schema->txn_rollback;
};

subtest 'job without dependencies' => sub {
    $driver->get('/tests/99981');
    my @dependencies_links = $driver->find_elements('Dependencies', 'link_text');
    is_deeply(\@dependencies_links, [], 'no dependency tab if no dependencies present');
};

subtest 'graph rendering' => sub {
    $driver->get('/tests/99938');
    $driver->find_element_by_link_text('Dependencies')->click();
    wait_for_ajax();
    ok(javascript_console_has_no_warnings_or_errors(), 'no unexpected js warnings');

    my $graph = $driver->find_element_by_id('dependencygraph');
    my $check_element_quandity = sub {
        my ($selector, $expected_count, $test_name) = @_;
        my @child_elements = $driver->find_child_elements($graph, $selector);
        is(scalar @child_elements, $expected_count, $test_name);
    };
    $check_element_quandity->('.cluster', 1, 'one cluster present');
    $check_element_quandity->('.edgePath', 3, 'three edges present');
    $check_element_quandity->('.node', 5, 'five nodes present');

    like(
        get_tooltip(99938),
        qr/.*opensuse-Factory-DVD-x86_64-Build0048-doc\@64bit.*START_AFTER_TEST=kde.*/,
        'tooltip for doc job'
    );
    like(
        get_tooltip(99963),
        qr/.*opensuse-13.1-DVD-x86_64-Build0091-kde\@64bit.*START_AFTER_TEST=doc.*PARALLEL_WITH=kde.*/,
        'tooltip for kde job 99963'
    );
    like(
        get_tooltip(99927),
        qr/.*opensuse-13.1-DVD-i586-Build0091-RAID0\@32bit.*START_DIRECTLY_AFTER_TEST=kde.*/,
        'tooltip for RAID0 job 99927'
    );
    like(get_tooltip(99961), qr/.*opensuse-13.1-NET-x86_64-Build0091-kde\@64bit.*<\/p>/, 'tooltip for kde job 99963');

    subtest 'cloned job' => sub {
        $driver->get('/tests/99945');
        $driver->find_element_by_link_text('Dependencies')->click();
        wait_for_ajax();
        $graph = $driver->find_element_by_id('dependencygraph');
        $check_element_quandity->('.cluster', 0, 'no cluster present (as only the latest job depends on cluster)');
        $check_element_quandity->('.edgePath', 2, 'two edges present (direct parent and sibling)');
        $check_element_quandity->('.node', 3, 'three nodes present (direct parent and sibling)');
    };
};

subtest 'overall behavior with advanced clusters' => sub {
    $dependencies->create({child_job_id => 99940, parent_job_id => 99963, dependency => PARALLEL});
    $dependencies->create({child_job_id => 80000, parent_job_id => 99940, dependency => PARALLEL});
    my $json = $t->get_ok('/tests/99961/dependencies_ajax')->status_is(200)->tx->res->json;
    my @expected_cluster = (80000, 99940, 99961, 99963), my $present_clusters = $json->{cluster};
    my @present_cluster_ids = keys %$present_clusters;
    is @present_cluster_ids, 1, 'exactly one cluster present';
    is_deeply [sort @{$present_clusters->{$present_cluster_ids[0]}}], \@expected_cluster,
      'parallel jobs shown in one big cluster';
};

kill_driver();
done_testing();
