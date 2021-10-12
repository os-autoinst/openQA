# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Case;
use OpenQA::Test::Utils qw(assume_all_assets_exist);
use OpenQA::SeleniumTest;
use OpenQA::JobDependencies::Constants;
use Date::Format 'time2str';

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $fixtures = '01-jobs.pl 06-job_dependencies.pl';
my $schema = $test_case->init_data(schema_name => $schema_name, fixtures_glob => $fixtures);

sub prepare_database {
    my $jobs = $schema->resultset('Jobs');

    # Populate more cluster jobs
    my @test_names = ('create_hdd', 'support_server', 'master_node', 'slave_node');
    for my $n (0 .. 3) {
        my $new = {
            id => 99900 + $n,
            group_id => 1001,
            priority => 35,
            result => 'failed',
            state => "done",
            t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 576600, 'UTC'),
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 576000, 'UTC'),
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            TEST => $test_names[$n],
            FLAVOR => 'DVD',
            DISTRI => 'opensuse',
            BUILD => '0091',
            VERSION => '13.1',
            MACHINE => '32bit',
            ARCH => 'i586',
            jobs_assets => [{asset_id => 1},],
            settings => [
                {key => 'QEMUCPU', value => 'qemu32'},
                {key => 'DVD', value => '1'},
                {key => 'VIDEOMODE', value => 'text'},
                {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'},
                {key => 'DESKTOP', value => 'textmode'},
                {key => 'ISO_MAXSIZE', value => '4700372992'}]};
        $jobs->create($new);
    }
    $jobs->find(99900)->children->create(
        {
            child_job_id => 99901,
            dependency => OpenQA::JobDependencies::Constants::CHAINED,
        });
    $jobs->find(99901)->children->create(
        {
            child_job_id => 99902,
            dependency => OpenQA::JobDependencies::Constants::PARALLEL,
        });
    $jobs->find(99901)->children->create(
        {
            child_job_id => 99903,
            dependency => OpenQA::JobDependencies::Constants::PARALLEL,
        });

    assume_all_assets_exist;
}

prepare_database;

my $last_job_id;
sub update_last_job_id {
    $last_job_id = $schema->resultset('Jobs')->search(undef, {rows => 1, order_by => {-desc => 'id'}})->first->id;
}
sub expected_job_id_regex {
    my ($offset) = @_;
    my $expected_job_id = $last_job_id + ($offset // 1);
    return qr|tests/$expected_job_id|;
}

driver_missing unless my $driver = call_driver;

$driver->title_is('openQA', 'on main page');
$driver->find_element_by_link_text('Login')->click();
is($driver->get('/tests'), 1, 'get /tests page');
wait_for_ajax();

subtest 'check single job restart in /tests page' => sub {
    subtest 'unable to restart' => sub {
        my $td = $driver->find_element('#job_99936 td.test');
        is($td->get_text(), 'kde@64bit-uefi', '99936 is kde@64bit-uefi');
        $driver->find_child_element($td, '.restart', 'css')->click();
        wait_for_ajax(msg => 'failed job restart');
        like(
            $driver->find_element('#flash-messages-finished-jobs')->get_text(),
            qr/Job 99936 misses.*\.iso.*Ensure to provide mandatory assets/s,
            'restarting job with missing asset results in an error'
        );
        is($td->get_text(), 'kde@64bit-uefi', 'job not marked as restarted');
        $driver->find_element('#flash-messages-finished-jobs button.force-restart')->click();
        wait_for_ajax(msg => 'forced job restart');
        is($td->get_text(), 'kde@64bit-uefi (restarted)', 'job is marked as restarted');
        $_->click for $driver->find_elements('#flash-messages-finished-jobs button.close');

    };
    subtest 'successful restart' => sub {
        update_last_job_id;
        my $td = $driver->find_element('#job_99926 td.test');
        is($td->get_text(), 'minimalx@32bit', '99926 is minimalx@32bit');
        $driver->find_child_element($td, '.restart', 'css')->click();
        wait_for_ajax(msg => 'successful job restart');
        is($td->get_text(), 'minimalx@32bit (restarted)', 'job is marked as restarted');
        like($driver->find_child_element($td, "./a[\@title='new test']", 'xpath')->get_attribute('href'),
            expected_job_id_regex, 'restart link is correct');

        # open restart link then verify its test name
        $driver->find_child_element($td, "./a[\@title='new test']", 'xpath')->click();
        like($driver->find_element('#info_box .card-header')->get_text(),
            qr/minimalx@32bit/, 'restarted job is correct');
    };
};

ok($driver->get('/tests'), 'back on /tests page');
wait_for_ajax();

my $first_tab = $driver->get_current_window_handle();
my $second_tab;

subtest 'check cluster jobs restart in /tests page' => sub {
    # Check chain jobs restart
    my $chained_parent = $driver->find_element('#job_99937 td.test');
    my $chained_child = $driver->find_element('#job_99938 td.test');
    is($chained_parent->get_text(), 'kde@32bit', 'chained parent is kde@32bit');
    is($chained_child->get_text(), 'doc@64bit', 'chained child is doc@64bit');

    # Restart chained parent job
    update_last_job_id;
    $driver->find_child_element($chained_parent, '.restart', 'css')->click();
    wait_for_ajax(msg => 'restart chained parent job');

    # Chained parent and its child should be marked as restarted
    is($chained_parent->get_text(), 'kde@32bit (restarted)', 'chained parent is marked as restarted');
    is($chained_child->get_text(), 'doc@64bit (restarted)', 'chained child is marked as restarted');

    # Check if restart links are correct
    my $parent_restart_link
      = $driver->find_child_element($chained_parent, "./a[\@title='new test']", 'xpath')->get_attribute('href');
    my $child_restart_link
      = $driver->find_child_element($chained_child, "./a[\@title='new test']", 'xpath')->get_attribute('href');
    like($parent_restart_link, expected_job_id_regex 1, 'restart link is correct');
    like($child_restart_link, expected_job_id_regex 2, 'restart link is correct');

    # Open tab for each restart link then verify its test name
    $second_tab = open_new_tab($parent_restart_link);
    $driver->switch_to_window($second_tab);
    like($driver->find_element('#info_box .card-header')->get_text(),
        qr/kde\@32bit/, 'restarted chained parent is correct');
    $driver->close();
    $driver->switch_to_window($first_tab);
    $second_tab = open_new_tab($child_restart_link);
    $driver->switch_to_window($second_tab);
    like($driver->find_element('#info_box .card-header')->get_text(),
        qr/doc\@64bit/, 'restarted chained child is correct');
    $driver->close();
    $driver->switch_to_window($first_tab);
    is($driver->get_title(), 'openQA: Test results', 'back to /tests page');

    # Check parallel jobs restart in page 2 of finished jobs
    my @page_next = $driver->find_elements('#results_next .page-link');
    (shift(@page_next))->click();
    wait_for_ajax();

    my $master_node = $driver->find_element('#job_99902 td.test');
    my $slave_node = $driver->find_element('#job_99903 td.test');
    my $support_server = $driver->find_element('#job_99901 td.test');
    is($master_node->get_text(), 'master_node@32bit', 'a parallel child is master_node@32bit');
    is($slave_node->get_text(), 'slave_node@32bit', 'a parallel child is slave_node@32bit');
    is($support_server->get_text(), 'support_server@32bit', 'a parallel parent is support_server@32bit');

    # Restart a parallel job
    update_last_job_id;
    $driver->find_child_element($master_node, '.restart', 'css')->click();
    wait_for_ajax(msg => 'restart parallel job');

    # All parallel jobs and their parent job should be marked as restarted
    is($master_node->get_text(), 'master_node@32bit (restarted)', 'parallel child master_node is marked as restarted');
    is($slave_node->get_text(), 'slave_node@32bit (restarted)', 'parallel child slave_node is marked as restarted');
    is(
        $support_server->get_text(),
        'support_server@32bit (restarted)',
        'parallel parent support_server is marked as restarted'
    );

    # Check if restart links are correct
    my $master_node_link
      = $driver->find_child_element($master_node, "./a[\@title='new test']", 'xpath')->get_attribute('href');
    my $slave_node_link
      = $driver->find_child_element($slave_node, "./a[\@title='new test']", 'xpath')->get_attribute('href');
    my $support_server_link
      = $driver->find_child_element($support_server, "./a[\@title='new test']", 'xpath')->get_attribute('href');
    like($master_node_link, expected_job_id_regex 2, 'restart link is correct');
    like($slave_node_link, expected_job_id_regex 3, 'restart link is correct');
    like($support_server_link, expected_job_id_regex 1, 'restart link is correct');

    # Open tab for each restart link then verify its test name
    $second_tab = open_new_tab($master_node_link);
    $driver->switch_to_window($second_tab);
    like($driver->find_element('#info_box .card-header')->get_text(),
        qr/master_node\@32bit/, 'restarted parallel child is correct');
    $driver->close();
    $driver->switch_to_window($first_tab);
    $second_tab = open_new_tab($slave_node_link);
    $driver->switch_to_window($second_tab);
    like($driver->find_element('#info_box .card-header')->get_text(),
        qr/slave_node\@32bit/, 'restarted parallel child is correct');
    $driver->close();
    $driver->switch_to_window($first_tab);
    $second_tab = open_new_tab($support_server_link);
    $driver->switch_to_window($second_tab);
    like($driver->find_element('#info_box .card-header')->get_text(),
        qr/support_server\@32bit/, 'restarted parallel parent is correct');
    $driver->close();
    $driver->switch_to_window($first_tab);
    is($driver->get_title(), 'openQA: Test results', 'back to /tests page');
};

subtest 'check cluster jobs restart in test overview page' => sub {
    # Refresh /tests page and cancel all 6 restarted jobs in previous tests
    ok($driver->get('/tests'), 'back on /tests page');
    wait_for_ajax(msg => 'job tables loaded');
    my @scheduled_tds = $driver->find_elements('#scheduled td.test');
    $driver->find_child_element($scheduled_tds[$_], '.cancel', 'css')->click for (0 .. 5);

    # Restart a parent job in test results overview page
    is($driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001'),
        1, 'go to test overview page');
    update_last_job_id;
    $driver->find_element('#res_DVD_i586_create_hdd .restart')->click();
    wait_for_ajax(msg => 'restart parent job in test results overview page');

    subtest 'all related cluster jobs marked as restarted' => sub {
        my @cluster_jobs = qw(create_hdd support_server master_node slave_node);
        is($driver->find_element("#res_DVD_i586_$_ .fa-circle")->get_attribute('title'), 'Scheduled', "$_ is restarted")
          for @cluster_jobs;
        my $i = 0;
        like(
            $driver->find_element("#res_DVD_i586_$_ .restarted")->get_attribute('href'),
            expected_job_id_regex ++$i,
            "restarted link for $_ is correct"
        ) for @cluster_jobs;
    };
};

subtest 'restart job from info panel in test results' => sub {
    subtest 'assets missing; there is no parent' => sub {
        is($driver->get('/tests/99939'), 1, 'go to job 99939');
        $driver->find_element('#restart-result')->click();
        wait_for_ajax(msg => 'fail to start job with missing asset and no parent');
        like($driver->get_current_url, qr|tests/99939|, 'no auto refresh when there are errors/warnings');
        like(
            $driver->find_element('#flash-messages')->get_text,
            qr/Job 99939 misses.*\.iso.*Ensure to provide mandatory assets/s,
            'restarting job with missing asset results in an error'
        );
    };
    subtest 'assets missing; there is a parent' => sub {
        $schema->resultset('JobDependencies')
          ->create(
            {child_job_id => 99939, parent_job_id => 99947, dependency => OpenQA::JobDependencies::Constants::CHAINED});
        is($driver->get('/tests/99939'), 1, 'go to job 99939');
        $driver->find_element('#restart-result')->click();
        wait_for_ajax(msg => 'fail to start job with missing asset and no parent');
        like(
            $driver->find_element('#flash-messages')->get_text,
            qr/Job 99939 misses.*\.iso.*You may try to retrigger the parent job/s,
            'restarting job with missing asset results in an error'
        );
    };
    subtest 'force restart' => sub {
        update_last_job_id;
        $driver->find_element('#flash-messages button.force-restart')->click();
        wait_for_ajax(msg => 'forced job restart');
        like($driver->find_element_by_link_text('new job')->get_attribute('href'),
            expected_job_id_regex, 'warning with link to new job appears');
    };
    subtest 'successful restart' => sub {
        is($driver->get('/tests/99946'), 1, 'go to job 99946');
        update_last_job_id;
        $driver->find_element('#restart-result')->click();
        wait_for_ajax(msg => 'successful restart from info panel in test results');
        like($driver->get_current_url(), expected_job_id_regex, 'auto refresh to restarted job');
        like($driver->find_element('#info_box .card-header')->get_text(),
            qr/textmode\@32bit/, 'restarted job is correct');
    };
};

kill_driver();
done_testing();
