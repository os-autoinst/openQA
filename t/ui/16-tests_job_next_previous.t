# Copyright (C) 2016 SUSE Linux GmbH
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

OpenQA::Test::Case->new->init_data;

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $driver = call_driver();
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# check job next and previous not loaded when open tests/x
my $get = $t->get_ok('/tests/99946')->status_is(200);
$get->element_exists_not(
    '#job_next_previous_table_wrapper .dataTables_wrapper',
    'datatable of job next and previous not loaded when open tests/x'
);

my $job_header = $t->tx->res->dom->at('#next_previous #scenario .h5');
like(
    OpenQA::Test::Case::trim_whitespace($job_header->all_text),
    qr/Next & previous results for opensuse-13.1-DVD-i586-textmode/,
    'header for job scenario'
);

# trigger job next and previous for current job
$driver->title_is('openQA', 'on main page');
$driver->find_element_by_link_text('All Tests')->click();
$driver->find_element('[href="/tests/99946"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

# check job next and previous for current job
is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')}, 4, 'job next and previous of 99946');
my $job99946 = $driver->find_element('#job_next_previous_table #job_result_99946');
my @tds = $driver->find_child_elements($job99946, 'td');
is((shift @tds)->get_text(), 'C',                                 '99946 is current job');
is((shift @tds)->get_text(), 'zypper_up',                         'failed module of 99946');
is((shift @tds)->get_text(), '0091',                              'build of 99946 is 0091');
is((shift @tds)->get_text(), 'about 3 hours ago ( 01:00 hours )', 'finished and duration of 99946');

my $job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'L', '99947 is the latest job');
my $state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed', 'the latest job 99947 was passed');
is((shift @tds)->get_text(),       '0092',         'build of 99947 is 0092');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99945')}, 1, 'found previous job 99945');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99944')}, 1, 'found previous job 99944');

# select the most previous job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99944"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')}, 4, 'job next and previous of 99944');
my $job99944 = $driver->find_element('#job_next_previous_table #job_result_99944');
@tds = $driver->find_child_elements($job99944, 'td');
is((shift @tds)->get_text(), 'C', '99944 is current job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: softfailed',                  'the latest job 99944 was softfailed');
is((shift @tds)->get_text(),       '0091',                              'build of 99944 is 0091');
is((shift @tds)->get_text(),       'about 4 hours ago ( 01:00 hours )', 'finished and duration of 99944');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99945')}, 1, 'found next job 99945');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')}, 1, 'found next job 99946');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1,
    'found next and latest job 99947');

# select the latest job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99947"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')}, 4, 'job next and previous of 99947');
$job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'C&L', '99947 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed',                      'the latest job 99947 was passed');
is((shift @tds)->get_text(),       '0092',                              'build of 99947 is 0092');
is((shift @tds)->get_text(),       'about 2 hours ago ( 01:58 hours )', 'finished and duration of 99947');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')}, 1, 'found previous job 99946');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99945')}, 1, 'found previous job 99945');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99944')}, 1, 'found previous job 99944');

# select limit from list for both of next and previous to render results table
$driver->find_element_by_xpath("//select[\@id='limit_num']/option[2]")->click();
wait_for_ajax();
is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')},
    4, 'job next and previous with limit list selected of 99947');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99944')}, 1, 'found previous job 99944');

#check build links to overview page
$driver->find_element_by_link_text('0091')->click();
is(
    $driver->find_element('#summary .card-header')->get_text(),
    'Overall Summary of opensuse 13.1 build 0091',
    'build links to overview page'
);

# check job next and previous of current running/scheduled job
$driver->find_element_by_link_text('All Tests')->click();
$driver->find_element('[href="/tests/99963"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')}, 2, 'job next and previous of 99963');
my $job99963 = $driver->find_element('#job_next_previous_table #job_result_99963');
@tds = $driver->find_child_elements($job99963, 'td');
is((shift @tds)->get_text(), 'C&L', '99963 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'running',          'job 99963 was running');
is((shift @tds)->get_text(),       '0091',             'build of 99963 is 0091');
is((shift @tds)->get_text(),       'Not yet: running', '99963 is not yet finished');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99962')}, 1, 'found previous job 99962');

$driver->find_element_by_link_text('All Tests')->click();
$driver->find_element('[href="/tests/99928"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')}, 1, 'job next and previous of 99928');
my $job99928 = $driver->find_element('#job_next_previous_table #job_result_99928');
@tds = $driver->find_child_elements($job99928, 'td');
is((shift @tds)->get_text(), 'C&L', '99928 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'scheduled',          'job 99928 was scheduled');
is((shift @tds)->get_text(),       '0091',               'build of 99928 is 0091');
is((shift @tds)->get_text(),       'Not yet: scheduled', '99928 is not yet finished');

kill_driver();
done_testing();
