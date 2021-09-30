#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Date::Format 'time2str';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Time::Seconds;
use OpenQA::Test::TimeLimit '40';
use OpenQA::Test::Case;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(assume_all_assets_exist);
use OpenQA::Jobs::Constants qw(NONE RUNNING);

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $fixtures = '01-jobs.pl 03-users.pl 04-products.pl 05-job_modules.pl 06-job_dependencies.pl';
my $schema = $test_case->init_data(schema_name => $schema_name, fixtures_glob => $fixtures);

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my @job_params = (
    group_id => 1002,
    priority => 35,
    result => NONE,
    state => RUNNING,
    t_finished => undef,
    t_started => time2str('%Y-%m-%d %H:%M:%S', time - 5 * ONE_MINUTE, 'UTC'),
    t_created => time2str('%Y-%m-%d %H:%M:%S', time - ONE_HOUR, 'UTC'),
    TEST => 'kde',
    ARCH => 'x86_64',
    BUILD => '0092',
    DISTRI => 'opensuse',
    FLAVOR => 'NET',
    MACHINE => '64bit',
    VERSION => '13.1'
);

# Customize the database based on fixtures.
# We do not need job 99981 right now so delete it here just to have a helpful
# example for customizing the test database
sub prepare_database {
    my $bugs = $schema->resultset('Bugs');
    my %bug_args = (refreshed => 1, existing => 1);
    my $bug1 = $bugs->create({bugid => 'poo#1', title => 'open poo bug', open => 1, %bug_args});
    my $bug2 = $bugs->create({bugid => 'poo#2', title => 'closed poo bug', open => 0, %bug_args});
    my $bug4 = $bugs->create({bugid => 'bsc#4', title => 'closed bugzilla bug', open => 0, %bug_args});

    my $jobs = $schema->resultset('Jobs');
    $jobs->find(99981)->delete;

    # add a few comments
    my $job99946_comments = $jobs->find(99946)->comments;
    $job99946_comments->create({text => 'test1', user_id => 99901});
    $job99946_comments->create({text => 'test2', user_id => 99901});
    my $job99963_comments = $jobs->find(99963)->comments;
    $job99963_comments->create({text => 'test1', user_id => 99901});
    $job99963_comments->create({text => 'test2', user_id => 99901});
    my $job99928_comments = $jobs->find(99928)->comments;
    $job99928_comments->create({text => 'test1', user_id => 99901});
    my $job99936_comments = $jobs->find(99936)->comments;
    $job99936_comments->create({text => 'poo#1', user_id => 99901});
    $job99936_comments->create({text => 'poo#2', user_id => 99901});
    # This bugref doesn't have a corresponding bug entry
    $job99936_comments->create({text => 'bsc#3', user_id => 99901});
    $job99936_comments->create({text => 'bsc#4', user_id => 99901});

    # add another running job which is "half done"
    my $running_job = $jobs->create({id => 99970, state => RUNNING, TEST => 'kde', @job_params});
    my @modules = (
        {name => 'start_install', category => 'installation', script => 'start_install.pm', result => 'passed'},
        {name => 'livecdreboot', category => 'installation', script => 'livecdreboot.pm', result => 'passed'},
        {name => 'aplay', category => 'console', script => 'aplay.pm', result => 'running'},
        {name => 'glibc_i686', category => 'console', script => 'glibc_i686.pm', result => 'none'},
    );
    $running_job->discard_changes;
    $running_job->insert_test_modules(\@modules);
    $running_job->update_module($_->{name}, {result => $_->{result}}) for @modules;

    my $job99940 = $jobs->find(99940);
    my %modules = (a => 'skip', b => 'ok', c => 'none', d => 'softfail', e => 'fail');
    foreach my $key (sort keys %modules) {
        $job99940->insert_module({name => $key, category => $key, script => $key});
        $job99940->update_module($key, {result => $modules{$key}, details => []});
    }

    my $schedule_job = $jobs->create(
        {
            @job_params,
            id => 99991,
            state => OpenQA::Jobs::Constants::SCHEDULED,
            TEST => 'kde_variant',
            settings =>
              [{key => 'JOB_TEMPLATE_NAME', value => 'kde_variant'}, {key => 'TEST_SUITE_NAME', value => 'kde'}]});

    assume_all_assets_exist;
}

prepare_database();

driver_missing unless my $driver = call_driver;

$driver->title_is("openQA", "on main page");
is($driver->get("/results"), 1, "/results gets");
like($driver->get_current_url(), qr{.*/tests}, 'legacy redirection from /results to /tests');

wait_for_ajax(msg => 'DataTables on "All tests" page');

# Test 99946 is successful (29/0/1)
my $job99946 = $driver->find_element('#results #job_99946');
my @tds = $driver->find_child_elements($job99946, 'td');
is(scalar @tds, 4, '4 columns displayed');
is((shift @tds)->get_text(), 'Build0091 of opensuse-13.1-DVD.i586', 'medium of 99946');
is((shift @tds)->get_text(), 'textmode@32bit', 'test of 99946');
is((shift @tds)->get_text(), '28 1 1', 'result of 99946 (passed, softfailed, failed)');
my $time = $driver->find_child_element(shift @tds, 'span');
$time->attribute_like('title', qr/.*Z/, 'finish time title of 99946');
$time->text_like(qr/about 3 hours ago/, 'finish time of 99946');

subtest 'running jobs, progress bars' => sub {
    is($driver->find_element('#job_99961 .progress-bar-striped')->get_text(),
        'running', 'striped progress bar if not modules present yet');
    is($driver->find_element('#job_99970 .progress-bar')->get_text(),
        '67 %', 'progress is 67 % if 2 modules finished, 1 is running and 1 is queued');
    # note: For simplicity the running module is ignored. That means 2 of only 3 modules
    #       have been finished and hence we get 67 %. I suppose that's not worse than counting
    #       the currently running module always as zero progress.

    # job which is still running but all modules are completed or skipped after failure
    isnt($driver->find_element('#running #job_99963'), undef, '99963 still running');
    like($driver->find_element('#job_99963 td.test a')->get_attribute('href'), qr{.*/tests/99963}, 'right link');
    is($driver->find_element('#job_99963 .progress-bar')->get_text(),
        '40 %', 'progress is 40 % if job fatally failed at this point (but status not updated to uploading/done)');
    $time = $driver->find_element('#job_99963 td.time span');
    $time->attribute_like('title', qr/.*Z/, 'right time title for running');
    $time->text_like(qr/1[01] minutes ago/, 'right time for running');
};

my @header = $driver->find_elements('h2');
my @header_texts = map { OpenQA::Test::Case::trim_whitespace($_->get_text()) } @header;
my @expected = ('3 jobs are running', '3 scheduled jobs', 'Last 11 finished jobs');
is_deeply(\@header_texts, \@expected, 'all headings correctly displayed');

$driver->get('/tests?limit=1');
wait_for_ajax(msg => 'DataTables on "All tests" page with limit');
@header = $driver->find_elements('h2');
@header_texts = map { OpenQA::Test::Case::trim_whitespace($_->get_text()) } @header;
@expected = ('3 jobs are running', '3 scheduled jobs', 'Last 1 finished jobs');
is_deeply(\@header_texts, \@expected, 'limit for finished tests can be adjusted with query parameter');

$t->get_ok('/tests/99963')->status_is(200);
$t->content_like(qr/State.*running/, "Running jobs are marked");

subtest 'available comments shown' => sub {
    $driver->get('/tests');
    wait_for_ajax(msg => 'DataTables on "All tests" page for comments');

    is(
        $driver->find_element('#job_99946 .fa-comment')->get_attribute('title'),
        '2 comments available',
        'available comments shown for finished jobs'
    );
    is(@{$driver->find_elements('#job_99962 .fa-comment')},
        0, 'available comments only shown if at least one comment available');
    is(
        $driver->find_element('#job_99936 .fa-bolt')->get_attribute('title'),
        "Bug referenced: poo#1\nopen poo bug",
        'available bugref (poo#1) shown for finished jobs'
    );
    is(
        $driver->find_element('#job_99936 .fa-bug')->get_attribute('title'),
        "Bug referenced: bsc#3",
        'available bugref (bsc#3) shown for finished jobs'
    );
    my @closed = $driver->find_elements('#job_99936 .bug_closed');
    is(
        $closed[1]->get_attribute('title'),
        "Bug referenced: poo#2\nclosed poo bug",
        'available bugref (poo#2) shown for finished jobs'
    );
    is(
        $closed[0]->get_attribute('title'),
        "Bug referenced: bsc#4\nclosed bugzilla bug",
        'available bugref (bsc#4) shown for finished jobs'
    );

  SKIP: {
        skip 'comment icon for running and scheduled jobs skipped to imporove performance', 2;
        is(
            $driver->find_element('#job_99963 .fa-comment')->get_attribute('title'),
            '2 comments available',
            'available comments shown for running jobs'
        );
        is(
            $driver->find_element('#job_99928 .fa-comment')->get_attribute('title'),
            '1 comment available',
            'available comments shown for scheduled jobs'
        );
    }
};

$driver->find_element_by_link_text('Build0091')->click();
like(
    $driver->find_element_by_id('summary')->get_text(),
    qr/Overall Summary of opensuse build 0091/,
    'we are on build 91'
);

# return
is($driver->get("/tests"), 1, "/tests gets");
wait_for_ajax(msg => 'wait for all tests displayed before looking for 99928');

# Test 99928 is scheduled
isnt($driver->find_element('#scheduled #job_99928'), undef, '99928 scheduled');
like($driver->find_element('#scheduled #job_99928 td.test a')->get_attribute('href'), qr{.*/tests/99928}, 'right link');
$time = $driver->find_element('#scheduled #job_99928 td.time span');
$time->attribute_like('title', qr/.*Z/, 'right time title for scheduled');
$time->text_like(qr/2 hours ago/, 'right time for scheduled');
$driver->find_element('#scheduled #job_99928 td.test a')->click();
$driver->title_is('openQA: opensuse-13.1-DVD-i586-Build0091-RAID1@32bit test results', 'tests/99928 followed');

# return
is($driver->get("/tests"), 1, "/tests gets");
wait_for_ajax();

# Test 99938 failed, so it should be displayed in red
my $job99938 = $driver->find_element('#results #job_99946');

is($driver->find_element('#results #job_99938 .test .status.result_failed')->get_text(), '', '99938 failed');
like($driver->find_element('#results #job_99938 td.test a')->get_attribute('href'), qr{.*/tests/99938}, 'right link');
$driver->find_element('#results #job_99938 td.test a')->click();
$driver->title_is('openQA: opensuse-Factory-DVD-x86_64-Build0048-doc@64bit test results', 'tests/99938 followed');

# return
is($driver->get("/tests"), 1, "/tests gets");
wait_for_ajax();

my @links = $driver->find_elements('#results #job_99946 td.test a', 'css');
is(@links, 3, 'only three links (icon, name and comments but no restart)');

# Test 99926 is displayed
is($driver->find_element('#results #job_99926 .test .status.result_incomplete')->get_text(), '', '99926 incomplete');

subtest 'priority of scheduled jobs' => sub {
    # displayed when not logged in
    is($driver->find_element('#job_99928 td + td + td')->get_text(), '46', 'priority displayed');
    my @prio_links = $driver->find_elements('#job_99928 td + td + td a');
    is_deeply(\@prio_links, [], 'no links to increase/decrease prio');

    # displayed and adjustable when logged in as admin
    $driver->find_element_by_link_text('Login')->click();
    $driver->get('/tests');
    wait_for_ajax;
    is($driver->find_element('#job_99928 .prio-value')->get_text(), '46', 'priority displayed');
    $driver->find_element('#job_99928 .prio-down')->click();
    wait_for_ajax;
    is($driver->find_element('#job_99928 .prio-value')->get_text(), '36', 'priority decreased');
    $driver->find_element('#job_99928 .prio-down')->click();
    wait_for_ajax;
    is($driver->find_element('#job_99928 .prio-value')->get_text(), '26', 'priority further decreased');
    $driver->find_element('#job_99928 .prio-up')->click();
    wait_for_ajax;
    is($driver->find_element('#job_99928 .prio-value')->get_text(), '36', 'priority further increased');

    $driver->get('/tests');
    wait_for_ajax;
    is($driver->find_element('#job_99928 .prio-value')->get_text(), '36', 'adjustment persists after reload');
    is($driver->find_element('#job_99927 .prio-value')->get_text(), '45', 'priority of other job not affected');
};

ok $driver->get('/logout'), 'logout';
ok $driver->get('/tests'), 'get tests';
wait_for_ajax(msg => 'wait for all tests displayed before looking for 99938');
# parent-child
my $child_e = $driver->find_element('#results #job_99938 .parent_child');
is($child_e->get_attribute('title'), "1 chained parent", "dep info");
is($child_e->get_attribute('data-children'), "[]", "no children");
is($child_e->get_attribute('data-parents'), "[99937]", "parent");

my $parent_e = $driver->find_element('#results #job_99937 .parent_child');
is($parent_e->get_attribute('title'), "1 chained child", "dep info");
is($parent_e->get_attribute('data-children'), "[99938]", "child");
is($parent_e->get_attribute('data-parents'), "[]", "no parents");

# no highlighting in first place
sub no_highlighting {
    is(scalar @{$driver->find_elements('#results #job_99937.highlight_parent')}, 0, 'parent not highlighted');
    is(scalar @{$driver->find_elements('#results #job_99938.highlight_child')}, 0, 'child not highlighted');
}
no_highlighting;

# job dependencies highlighted on hover
$driver->move_to(element => $child_e);
is(scalar @{$driver->find_elements('#results #job_99937.highlight_parent')}, 1, 'parent highlighted');
$driver->move_to(element => $parent_e);
is(scalar @{$driver->find_elements('#results #job_99938.highlight_child')}, 1, 'child highlighted');
$driver->move_to(xoffset => 200, yoffset => 500);
no_highlighting;

# first check the relevant jobs
my @jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};

is_deeply(
    \@jobs,
    [qw(job_99940 job_99939 job_99938 job_99926 job_99936 job_99947 job_99962 job_99946 job_80000 job_99937)],
    '99945 is not displayed'
);
$driver->find_element_by_id('relevantfilter')->click();
wait_for_ajax();

# Test 99945 is not longer relevant (replaced by 99946) - but displayed for all
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(
    \@jobs,
    [qw(job_99940 job_99939 job_99938 job_99926 job_99936 job_99947 job_99962 job_99946 job_99945 job_99944)],
    'all rows displayed'
);

# test filtering finished jobs by result
my $filter_input = $driver->find_element('#finished_jobs_result_filter_chosen input', 'css');
$filter_input->click();
$filter_input->send_keys('Passed');
$driver->find_element('#finished_jobs_result_filter_chosen .active-result', 'css')->click();
# actually this does not use AJAX, but be sure all JavaScript processing is done anyways
wait_for_ajax();
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(\@jobs, [qw(job_99947 job_99946 job_99945 job_80000 job_99937 job_99764)], 'only passed jobs displayed');
$driver->find_element('#finished_jobs_result_filter_chosen .search-choice-close', 'css')->click();
# enable filter via query parameter, this time disable relevantfilter
$driver->get('/tests?resultfilter=Failed&foo=bar&resultfilter=Softfailed');
$driver->find_element_by_id('relevantfilter')->click();
wait_for_ajax_and_animations();
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(
    \@jobs,
    [qw(job_99940 job_99939 job_99938 job_99936 job_99962 job_99944)],
    'only softfailed and failed jobs displayed'
);
$driver->find_element('#finished_jobs_result_filter_chosen .search-choice-close', 'css')->click();
$driver->find_element('#finished_jobs_result_filter_chosen .search-choice-close', 'css')->click();

# now toggle back
$driver->find_element_by_id('relevantfilter')->click();
wait_for_ajax();

@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(
    \@jobs,
    [qw(job_99940 job_99939 job_99938 job_99926 job_99936 job_99947 job_99962 job_99946 job_80000 job_99937)],
    '99945 again hidden'
);

$driver->get('/tests?match=staging_e');
wait_for_ajax();

@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('tbody tr', 'css')};
ok !$jobs[0], 'no running job matching';
ok !$jobs[1], 'no scheduled job matching';
is $jobs[2], 'job_99926', 'exactly one finished job matching';

$driver->get('/tests');
wait_for_ajax();
my @cancel_links = $driver->find_elements('#job_99928 a.cancel');
is(scalar @cancel_links, 0, 'no cancel link when not logged in');

# now login to test restart links
$driver->find_element_by_link_text('Login')->click();
is($driver->get('/tests'), 1, 'back on /tests');
wait_for_ajax();

@cancel_links = $driver->find_elements('#job_99928 a.cancel');
is(scalar @cancel_links, 1, 'cancel link displayed when logged in');

my $td = $driver->find_element('#job_99946 td.test');
is($td->get_text(), 'textmode@32bit', 'correct test name');

$driver->find_child_element($td, '.restart', 'css')->click();
wait_for_ajax();

$driver->title_is('openQA: Test results', 'restart stays on page');
$td = $driver->find_element('#job_99946 td.test');
is($td->get_text(), 'textmode@32bit (restarted)', 'restart removes link');

subtest 'check test results of job99940' => sub {
    $driver->get('/tests');
    wait_for_ajax;
    my $results = $driver->find_elements('#job_99940 > td')->[2];
    $results = $driver->find_child_element($results, 'a');
    my @count = split(/\s+/, $results->get_text());
    my @types = $driver->find_child_elements($results, 'i');
    is(@count, @types, "each number has a type");
    for my $class (qw(module_passed module_failed module_softfailed module_none module_skipped)) {
        is(scalar(@{$driver->find_child_elements($results, 'i.' . $class)}), 1, "$class displayed");
    }
};

subtest 'test name and description still show up correctly using JOB_TEMPLATE_NAME' => sub {
    $driver->get('/tests');
    wait_for_ajax(msg => 'wait for all tests displayed before looking for 99991');
    is($driver->find_element('#job_99991 td.test')->get_text(),
        'kde_variant@64bit', 'job 99991 displays TEST correctly');

    $driver->get('/tests/99991#settings');
    wait_for_ajax;
    is(
        $driver->find_element('#scenario-description')->get_text(),
        'Simple kde test, before advanced_kde',
        'job 99991 description displays correctly'
    );
};

kill_driver();
done_testing();
