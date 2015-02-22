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

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA');

my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 18;
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
$driver->find_element('div.big-button a', 'css')->click();
is($driver->get_current_url(), $baseurl . "tests/", "on /tests");

my $get;

#
# Test the legacy redirection
#
is(1, $driver->get($baseurl . "results"), "/results gets");
is($driver->get_current_url(), $baseurl . "tests", "/results redirects to /tests ");

# Test 99946 is successful (29/0/1)
my $job99946 = $driver->find_element('#results #job_99946', 'css');
my @tds = $driver->find_child_elements($job99946, "td");
is((shift @tds)->get_text(), 'Build0091 of opensuse-13.1-DVD.i586', "medium of 99946");
is((shift @tds)->get_text(), 'textmode@32bit', "test of 99946");
is((shift @tds)->get_text(), "", "no deps of 99946");
like((shift @tds)->get_text(), qr/a minute ago/, "time of 99946");
is((shift @tds)->get_text(), '29 1', "result of 99946");

# Test 99963 is still running
isnt(undef, $driver->find_element('#running #job_99963', 'css'), '99963 still running');

# Test 99928 is scheduled
isnt(undef, $driver->find_element('#scheduled #job_99928', 'css'), '99928 scheduled');

# Test 99938 failed, so it should be displayed in red
my $job99938 = $driver->find_element('#results #job_99946', 'css');

is('doc@64bit', $driver->find_element('#results #job_99938 .test .overview_failed', 'css')->get_text(), '99938 failed');

# Test 99926 is displayed
is('minimalx@32bit', $driver->find_element('#results #job_99926 .test .overview_incomplete', 'css')->get_text(), '99926 incomplete');

# first check the relevant jobs
my @jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};

is_deeply([qw(job_99962 job_99946 job_99938 job_99937 job_99926)], \@jobs, '5 rows (relevant) displayed');
$driver->find_element('#relevantfilter', 'css')->click();
# leave the ajax some time
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
# Test 99945 is not longer relevant (replaced by 99946) - but displayed for all
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply([qw(job_99962 job_99946 job_99945 job_99938 job_99937 job_99926)], \@jobs, '6 rows (all) displayed');

# now toggle back
#print $driver->get_page_source();
$driver->find_element('#relevantfilter', 'css')->click();
# leave the ajax some time
while (!$driver->execute_script("return jQuery.active == 0")) {
    sleep 1;
}
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply([qw(job_99962 job_99946 job_99938 job_99937 job_99926)], \@jobs, '5 rows (relevant) again displayed');

$driver->get($baseurl . "tests?match=staging_e");
#print $driver->get_page_source();
@jobs = map { $_->get_attribute('id') } @{$driver->find_elements('#results tbody tr', 'css')};
is_deeply([qw(job_99926)], \@jobs, '1 matching job');
is(1, @{$driver->find_elements('table.dataTable', 'css')}, 'no scheduled, no running matching');

t::ui::PhantomTest::kill_phantom();
done_testing();
