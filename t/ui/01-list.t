#! /usr/bin/perl

# Copyright (C) 2014-2018 SUSE LLC
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
use Date::Format 'time2str';
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Test::Database;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ws = OpenQA::WebSockets->new;
my $sh = OpenQA::Scheduler->new;

OpenQA::Test::Case->new->init_data;

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# By defining a custom hook we can customize the database based on fixtures.
# We do not need job 99981 right now so delete it here just to have a helpful
# example for customizing the test database
sub schema_hook {
    my $schema = OpenQA::Test::Database->new->create;
    my $jobs   = $schema->resultset('Jobs');
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

    # add another running job which is half done
    my $running_job = $jobs->create(
        {
            id         => 99970,
            group_id   => 1002,
            priority   => 35,
            result     => OpenQA::Jobs::Constants::NONE,
            state      => OpenQA::Jobs::Constants::RUNNING,
            t_finished => undef,
            backend    => 'qemu',
            # 5 minutes ago
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 300, 'UTC'),
            # 1 hour ago
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),
            TEST      => 'kde',
            ARCH      => 'x86_64',
            BUILD     => '0092',
            DISTRI    => 'opensuse',
            FLAVOR    => 'NET',
            MACHINE   => '64bit',
            VERSION   => '13.1'
        });
    my $running_job_modules = $running_job->modules;
    $running_job_modules->create(
        {
            script   => 'tests/installation/start_install.pm',
            category => 'installation',
            name     => 'start_install',
            result   => 'passed',
        });
    $running_job_modules->create(
        {
            script   => 'tests/installation/livecdreboot.pm',
            category => 'installation',
            name     => 'livecdreboot',
            result   => 'passed',
        });
    $running_job_modules->create(
        {
            script   => 'tests/console/aplay.pm',
            category => 'console',
            name     => 'aplay',
            result   => 'running',
        });
    $running_job_modules->create(
        {
            script   => 'tests/console/glibc_i686.pm',
            category => 'console',
            name     => 'glibc_i686',
            result   => 'none',
        });

    my $job99940 = $jobs->find(99940);
    my %modules  = (a => 'skip', b => 'ok', c => 'none', d => 'softfail', e => 'fail');
    while (my ($k, $v) = each %modules) {
        $job99940->insert_module({name => $k, category => $k, script => $k});
        $job99940->update_module($k, {result => $v, details => []});
    }
}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

$driver->title_is("openQA", "on main page");
is($driver->get("/results"), 1, "/results gets");
like($driver->get_current_url(), qr{.*/tests}, 'legacy redirection from /results to /tests');

wait_for_ajax();

# Test 99946 is successful (29/0/1)
my $job99946 = $driver->find_element('#results #job_99946');
my @tds      = $driver->find_child_elements($job99946, 'td');
is(scalar @tds,              4,                                     '4 columns displayed');
is((shift @tds)->get_text(), 'Build0091 of opensuse-13.1-DVD.i586', 'medium of 99946');
is((shift @tds)->get_text(), 'textmode@32bit',                      'test of 99946');
is((shift @tds)->get_text(), '28 1 1',                              'result of 99946 (passed, softfailed, failed)');
my $time = $driver->find_child_element(shift @tds, 'span');
$time->attribute_like('title', qr/.*Z/, 'finish time title of 99946');
$time->text_like(qr/about 3 hours ago/, 'finish time of 99946');

subtest 'running jobs, progress bars' => sub {
    is($driver->find_element('#job_99961 .progress-bar-striped')->get_text(),
        'running', 'striped progress bar if not modules');
    is($driver->find_element('#job_99970 .progress-bar')->get_text(),
        '50 %', 'progress is 50 % if module 3 of 4 is currently executed');

    # job which is still running but all modules are completed or skipped after failure
    isnt($driver->find_element('#running #job_99963'), undef, '99963 still running');
    like($driver->find_element('#job_99963 td.test a')->get_attribute('href'), qr{.*/tests/99963}, 'right link');
    is($driver->find_element('#job_99963 .progress-bar')->get_text(),
        '100 %', 'progress is 100 % if all modules completed');
    $time = $driver->find_element('#job_99963 td.time span');
    $time->attribute_like('title', qr/.*Z/, 'right time title for running');
    $time->text_like(qr/1[01] minutes ago/, 'right time for running');
};

$driver->get('/tests');
wait_for_ajax;
my @header       = $driver->find_elements('h2');
my @header_texts = map { OpenQA::Test::Case::trim_whitespace($_->get_text()) } @header;
my @expected     = ('3 jobs are running', '2 scheduled jobs', 'Last 11 finished jobs');
is_deeply(\@header_texts, \@expected, 'all headings correctly displayed');

$driver->get('/tests?limit=1');
wait_for_ajax;
@header       = $driver->find_elements('h2');
@header_texts = map { OpenQA::Test::Case::trim_whitespace($_->get_text()) } @header;
@expected     = ('3 jobs are running', '2 scheduled jobs', 'Last 1 finished jobs');
is_deeply(\@header_texts, \@expected, 'limit for finished tests can be adjusted with query parameter');

my $get = $t->get_ok('/tests/99963')->status_is(200);
$t->content_like(qr/State.*running/, "Running jobs are marked");

subtest 'available comments shown' => sub {
    $driver->get('/tests');
    wait_for_ajax;

    is(
        $driver->find_element('#job_99946 .fa-comment')->get_attribute('title'),
        '2 comments available',
        'available comments shown for finished jobs'
    );
    is(@{$driver->find_elements('#job_99962 .fa-comment')},
        0, 'available comments only shown if at least one comment available');

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

$driver->get('/logout');
$driver->get('/tests');

# parent-child
my $child_e = $driver->find_element('#results #job_99938 .parent_child');
is($child_e->get_attribute('title'),         "1 chained parent", "dep info");
is($child_e->get_attribute('data-children'), "[]",               "no children");
is($child_e->get_attribute('data-parents'),  "[99937]",          "parent");

my $parent_e = $driver->find_element('#results #job_99937 .parent_child');
is($parent_e->get_attribute('title'),         "1 chained child", "dep info");
is($parent_e->get_attribute('data-children'), "[99938]",         "child");
is($parent_e->get_attribute('data-parents'),  "[]",              "no parents");

# no highlighting in first place
sub no_highlighting {
    is(scalar @{$driver->find_elements('#results #job_99937.highlight_parent')}, 0, 'parent not highlighted');
    is(scalar @{$driver->find_elements('#results #job_99938.highlight_child')},  0, 'child not highlighted');
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
wait_for_ajax();
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
is_deeply(\@jobs, ['', '', 'job_99926'], '1 job matching');
# note: the first 2 empty IDs are the 'not found' row of the data tables for running and
#       scheduled jobs

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


kill_driver();
done_testing();
