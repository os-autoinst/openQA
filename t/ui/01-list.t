# Copyright (C) 2014 SUSE Linux Products GmbH
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
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 37;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

#
# List with no parameters
#
is($driver->get_title(), "openQA", "on main page");
my $baseurl = $driver->get_current_url();

my $get;

#
# Test the legacy redirection
#
is($driver->get($baseurl . "results"), 1, "/results gets");
is($driver->get_current_url(), $baseurl . "tests", "/results redirects to /tests ");

#print $driver->get_page_source();

# Test 99946 is successful (29/0/1)
my $job99946 = $driver->find_element('#results #job_99946', 'css');
my @tds = $driver->find_child_elements($job99946, "td");
is((shift @tds)->get_text(), 'Build0091 of opensuse-13.1-DVD.i586', "medium of 99946");
is((shift @tds)->get_text(), 'textmode@32bit',                      "test of 99946");
is((shift @tds)->get_text(), '29 1',                                "result of 99946");
like((shift @tds)->get_text(), qr/a minute ago/, "time of 99946");

# Test 99963 is still running
isnt($driver->find_element('#running #job_99963', 'css'), undef, '99963 still running');
is($driver->find_element('#running #job_99963 td.test a', 'css')->get_attribute('href'), "$baseurl" . "tests/99963", 'right link');
like($driver->find_element('#running #job_99963 td.time', 'css')->get_text(), qr/1[01] minutes ago/, 'right time for running');

$driver->find_element('Build0091', 'link_text')->click();
like($driver->find_element('#summary', 'css')->get_text(), qr/Overall Summary of opensuse build 0091/, 'we are on build 91');

#$driver->find_element('#running #job_99963 td.test a', 'css')->click();
#is($driver->get_title(), 'job 99963');

# return
is($driver->get($baseurl . "tests"), 1, "/tests gets");

# Test 99928 is scheduled
isnt($driver->find_element('#scheduled #job_99928', 'css'), undef, '99928 scheduled');
is($driver->find_element('#scheduled #job_99928 td.test a', 'css')->get_attribute('href'), "$baseurl" . "tests/99928", 'right link');
$driver->find_element('#scheduled #job_99928 td.test a', 'css')->click();
is($driver->get_title(), 'openQA: opensuse-13.1-DVD-i586-Build0091-RAID1 test results', 'tests/99928 followed');

# return
is($driver->get($baseurl . "tests"), 1, "/tests gets");

# Test 99938 failed, so it should be displayed in red
my $job99938 = $driver->find_element('#results #job_99946', 'css');

is($driver->find_element('#results #job_99938 .test .status.result_failed', 'css')->get_text(), '', '99938 failed');
is($driver->find_element('#results #job_99938 td.test a', 'css')->get_attribute('href'), "$baseurl" . "tests/99938", 'right link');
$driver->find_element('#results #job_99938 td.test a', 'css')->click();
is($driver->get_title(), 'openQA: opensuse-Factory-DVD-x86_64-Build0048-doc test results', 'tests/99938 followed');

# return
is($driver->get($baseurl . "tests"), 1, "/tests gets");
my @links = $driver->find_elements('#results #job_99946 td.test a', 'css');
is(@links, 2, 'only two links (icon, name, no restart)');

# Test 99926 is displayed
is($driver->find_element('#results #job_99926 .test .status.result_incomplete', 'css')->get_text(), '', '99926 incomplete');

# parent-child
my $child_e = $driver->find_element('#results #job_99938 .parent_child', 'css');
is($child_e->get_attribute('title'),         "1 Chained parent", "dep info");
is($child_e->get_attribute('data-children'), "[]",               "no children");
is($child_e->get_attribute('data-parents'),  "[99937]",          "parent");

my $parent_e = $driver->find_element('#results #job_99937 .parent_child', 'css');
is($parent_e->get_attribute('title'),         "1 Chained child", "dep info");
is($parent_e->get_attribute('data-children'), "[99938]",         "child");
is($parent_e->get_attribute('data-parents'),  "[]",              "no parents");

# first check the relevant jobs
my @jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};

is_deeply(\@jobs, [qw(job_99981 job_99962 job_99946 job_99939 job_99938 job_99937 job_99926)], '6 rows (relevant) displayed');
$driver->find_element('#relevantfilter', 'css')->click();
# leave the ajax some time
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
# Test 99945 is not longer relevant (replaced by 99946) - but displayed for all
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(\@jobs, [qw(job_99981 job_99962 job_99946 job_99945 job_99939 job_99938 job_99937 job_99926)], '7 rows (all) displayed');

# now toggle back
#print $driver->get_page_source();
$driver->find_element('#relevantfilter', 'css')->click();
# leave the ajax some time
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(\@jobs, [qw(job_99981 job_99962 job_99946 job_99939 job_99938 job_99937 job_99926)], '6 rows (relevant) again displayed');

$driver->get($baseurl . "tests?match=staging_e");
#print $driver->get_page_source();
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply(\@jobs, [qw(job_99926)], '1 matching job');
is(@{$driver->find_elements('table.dataTable', 'css')}, 1, 'no scheduled, no running matching');

# now login to test restart links
$driver->find_element('Login', 'link_text')->click();
is($driver->get($baseurl . "tests"), 1, "/tests gets");
my $td = $driver->find_element('#results #job_99946 td.test', 'css');
is($td->get_text(), 'textmode@32bit', 'correct test name');

# click restart
$driver->find_child_element($td, '.restart', 'css')->click();
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
is($driver->get_title(), 'openQA: Test results', 'restart stays on page');
$td = $driver->find_element('#results #job_99946 td.test', 'css');
is($td->get_text(), 'textmode@32bit (restarted)', 'restart removes link');

#t::ui::PhantomTest::make_screenshot('mojoResults.png');

t::ui::PhantomTest::kill_phantom();
done_testing();
