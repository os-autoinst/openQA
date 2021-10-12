# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::SeleniumTest;
use OpenQA::Schema::Result::JobDependencies;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 05-job_modules.pl 06-job_dependencies.pl'
);

sub prepare_database {
    my $jobs = $schema->resultset('Jobs');
    my $dependencies = $schema->resultset('JobDependencies');

    # make doc job a clone of the textmode job
    my $doc_job_id = 99938;
    my $textmode_job = $jobs->find(99945);
    $textmode_job->update({clone_id => $doc_job_id});

    # insert dependencies (in addition to existing ones in regular fixtures) to get the following graph:
    #             => textmode (99945)
    # kde (99937) => doc (99938)      => kde (99963)
    #                                    kde (99961) => RAID0 (99927)
    # (99963 and 99961 are a cluster/parallel)
    # (99945 is hidden because it is a clone of 99938)
    # (99927 follows 99961 *directly*)
    $dependencies->create(
        {
            child_job_id => 99963,
            parent_job_id => 99938,
            dependency => OpenQA::JobDependencies::Constants::CHAINED,
        });
    $dependencies->create(
        {
            child_job_id => 99945,
            parent_job_id => 99937,
            dependency => OpenQA::JobDependencies::Constants::CHAINED,
        });
    $dependencies->create(
        {
            child_job_id => 99927,
            parent_job_id => 99961,
            dependency => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
        });
    # note: This cluster makes no sense but that is not the point of this test.
}

prepare_database;

driver_missing unless my $driver = call_driver;

sub get_tooltip {
    my ($job_id) = @_;
    return $driver->execute_script("return \$('#nodeTable$job_id').closest('.node').data('original-title');");
}

subtest 'dependency json' => sub {
    my $baseurl = $driver->get_current_url;
    my $t = Test::Mojo->new;
    my $app = $t->app;
    $t->ua(OpenQA::Client->new->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);

    $t->get_ok($baseurl . 'tests/99981/dependencies_ajax')->status_is(200)->json_is(
        '' => {
            cluster => {},
            edges => [],
            nodes => [
                {
                    blocked_by_id => undef,
                    id => 99981,
                    label => 'RAID0@32bit',
                    result => 'skipped',
                    state => 'cancelled',
                    name => 'opensuse-13.1-GNOME-Live-i686-Build0091-RAID0@32bit',
                    chained => [],
                    directly_chained => [],
                    parallel => [],
                }]
        },
        'single node for job without dependencies'
    );
    diag explain $t->tx->res->json unless $t->success;

    $t->get_ok($baseurl . 'tests/99938/dependencies_ajax')->status_is(200)->json_is(
        '' => {
            cluster => {
                cluster_99963 => [99963, 99961]
            },
            edges => [
                {
                    from => 99937,
                    to => 99938,
                },
                {
                    from => 99961,
                    to => 99927,
                },
                {
                    from => 99938,
                    to => 99963,
                }
            ],
            nodes => [
                {
                    blocked_by_id => undef,
                    id => 99938,
                    label => 'doc@64bit',
                    result => 'failed',
                    state => 'done',
                    name => 'opensuse-Factory-DVD-x86_64-Build0048-doc@64bit',
                    chained => ['kde'],
                    directly_chained => [],
                    parallel => [],


                },
                {
                    blocked_by_id => undef,
                    id => 99937,
                    label => 'kde@32bit',
                    result => 'passed',
                    state => 'done',
                    name => 'opensuse-13.1-DVD-i586-Build0091-kde@32bit',
                    chained => [],
                    directly_chained => [],
                    parallel => [],
                },
                {
                    blocked_by_id => undef,
                    id => 99963,
                    label => 'kde@64bit',
                    result => 'none',
                    state => 'running',
                    name => 'opensuse-13.1-DVD-x86_64-Build0091-kde@64bit',
                    chained => ['doc'],
                    directly_chained => [],
                    parallel => ['kde'],
                },
                {
                    blocked_by_id => undef,
                    id => 99961,
                    label => 'kde@64bit',
                    result => 'none',
                    state => 'running',
                    name => 'opensuse-13.1-NET-x86_64-Build0091-kde@64bit',
                    chained => [],
                    directly_chained => [],
                    parallel => [],
                },
                {
                    blocked_by_id => undef,
                    id => 99927,
                    label => 'RAID0@32bit',
                    result => 'none',
                    state => 'scheduled',
                    name => 'opensuse-13.1-DVD-i586-Build0091-RAID0@32bit',
                    chained => [],
                    directly_chained => ['kde'],
                    parallel => [],
                }]
        },
        'nodes, edges and cluster computed'
    );

    diag explain $t->tx->res->json unless $t->success;
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

    my $graph = $driver->find_element_by_id('dependencygraph');
    my $check_element_quandity = sub {
        my ($selector, $expected_count, $test_name) = @_;
        my @child_elements = $driver->find_child_elements($graph, $selector);
        is(scalar @child_elements, $expected_count, $test_name);
    };
    $check_element_quandity->('.cluster', 1, 'one cluster present');
    $check_element_quandity->('.edgePath', 3, 'two edges present');
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
    like(get_tooltip(99961), qr/.*opensuse-13.1-NET-x86_64-Build0091-kde\@64bit<\/p>/, 'tooltip for kde job 99963');
};

kill_driver();
done_testing();
