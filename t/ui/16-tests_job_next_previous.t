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
use Date::Format 'time2str';

OpenQA::Test::Case->new->init_data;

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub schema_hook {
    my $schema = OpenQA::Test::Database->new->create;
    my $jobs   = $schema->resultset('Jobs');

    # Populate more jobs to test page setting and inlcude incompletes
    for my $n (1 .. 15) {
        my $result = $n < 8 ? 'passed' : 'incomplete';
        my $new = {
            id          => 99900 + $n,
            group_id    => 1001,
            priority    => 35,
            result      => $result,
            state       => "done",
            backend     => 'qemu',
            t_finished  => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),
            t_started   => time2str('%Y-%m-%d %H:%M:%S', time - 18000, 'UTC'),
            t_created   => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            TEST        => "textmode",
            FLAVOR      => 'DVD',
            DISTRI      => 'opensuse',
            BUILD       => '0091',
            VERSION     => '13.1',
            MACHINE     => '32bit',
            ARCH        => 'i586',
            jobs_assets => [{asset_id => 1},],
            settings    => [
                {key => 'QEMUCPU',     value => 'qemu32'},
                {key => 'DVD',         value => '1'},
                {key => 'VIDEOMODE',   value => 'text'},
                {key => 'ISO',         value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'},
                {key => 'DESKTOP',     value => 'textmode'},
                {key => 'ISO_MAXSIZE', value => '4700372992'}]};
        $jobs->create($new);
    }
}

my $driver = call_driver(\&schema_hook);
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
my ($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99946');
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
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99945')},
    1, 'found nearest previous job 99945');
is(scalar @{$driver->find_elements("//*[\@title='Done: incomplete']", 'xpath')}, 6, 'include 6 incomletes in page 1');
$driver->find_element_by_link_text('Next')->click();
is(scalar @{$driver->find_elements("//*[\@title='Done: incomplete']", 'xpath')}, 2, 'include 2 incomletes in page 2');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99901')},
    1, 'found farmost previous job 99901');

# select the most previous job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99901"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99901');
my $init_page = $driver->find_element_by_xpath("//*[\@class='paginate_button page-item active']")->get_text();
is($init_page, 2, 'init page is 2 for 99901');
my $job99901 = $driver->find_element('#job_next_previous_table #job_result_99901');
@tds = $driver->find_child_elements($job99901, 'td');
is((shift @tds)->get_text(), 'C', '99901 is current job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed',                      'the latest job 99901 was passed');
is((shift @tds)->get_text(),       '0091',                              'build of 99901 is 0091');
is((shift @tds)->get_text(),       'about 4 hours ago ( 01:00 hours )', 'finished and duration of 99901');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99902')}, 1, 'found nearest next job 99902');
$driver->find_element_by_link_text('Previous')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')}, 1, 'found farmost next job 99946');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1,
    'found next and latest job 99947');

# select the latest job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99947"]')->click();
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99947');
$job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'C&L', '99947 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed',                      'the latest job 99947 was passed');
is((shift @tds)->get_text(),       '0092',                              'build of 99947 is 0092');
is((shift @tds)->get_text(),       'about 2 hours ago ( 01:58 hours )', 'finished and duration of 99947');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')},
    1, 'found nearest previous job 99946');
$driver->find_element_by_link_text('Next')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99901')},
    1, 'found farmost previous job 99901');

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

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 2, '2 entries found for 99963');
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

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 1, '1 entries found for 99928');
my $job99928 = $driver->find_element('#job_next_previous_table #job_result_99928');
@tds = $driver->find_child_elements($job99928, 'td');
is((shift @tds)->get_text(), 'C&L', '99928 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'scheduled',          'job 99928 was scheduled');
is((shift @tds)->get_text(),       '0091',               'build of 99928 is 0091');
is((shift @tds)->get_text(),       'Not yet: scheduled', '99928 is not yet finished');

# check job next and previous under tests/latest route
$driver->get('/tests/latest');
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 1, '1 entries found for 99981');
my $job99981 = $driver->find_element('#job_next_previous_table #job_result_99981');
@tds = $driver->find_child_elements($job99981, 'td');
is((shift @tds)->get_text(), 'C&L', '99981 is current and the latest job');

# check job next and previous with scenario latest url
$driver->get('/tests/99945');
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');
$driver->find_element_by_link_text('latest job for this scenario')->click();
my $scenario_latest_url = $driver->get_current_url();
like($scenario_latest_url, qr/latest?/,         'latest scenario URL includes latest');
like($scenario_latest_url, qr/arch=i586/,       'latest scenario URL includes architecture');
like($scenario_latest_url, qr/flavor=DVD/,      'latest scenario URL includes flavour');
like($scenario_latest_url, qr/test=textmode/,   'latest scenario URL includes test');
like($scenario_latest_url, qr/version=13.1/,    'latest scenario URL includes version');
like($scenario_latest_url, qr/machine=32bit/,   'latest scenario URL includes machine');
like($scenario_latest_url, qr/distri=opensuse/, 'latest scenario URL includes distri');
$driver->find_element_by_link_text('Next & previous results')->click();
wait_for_ajax();
$driver->find_element_by_class('dataTables_wrapper');
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99947');
$job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'C&L', '99947 is current and the latest job');

# check limit with query parameters of job next & previous
$driver->get('/tests/99947?previous_limit=10#next_previous');
wait_for_ajax();
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 11, '10 previous of 99947 and itself shown');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1, 'found current job 99947');
$driver->find_element_by_link_text('Next')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99909')}, 1, 'found 10th previous job 99909');

$driver->get('/tests/99901?next_limit=10#next_previous');
wait_for_ajax();
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 12, '10 next of 99901, itself and the latest shown');
$init_page = $driver->find_element_by_xpath("//*[\@class='paginate_button page-item active']")->get_text();
is($init_page,                                                                     2, 'init page is 2 for 99901');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99901')}, 1, 'found current job 99901');
$driver->find_element_by_link_text('Previous')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1, 'found the latest job 99947');

$driver->get('/tests/99908?previous_limit=3&next_limit=2#next_previous');
wait_for_ajax();
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 7, '3 previous and 2 next of 99901, itself and the latest shown');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99908')}, 1, 'found current job 99908');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1, 'found the latest job 99947');

$driver->get('/tests/latest?previous_limit=1&next_limit=1#next_previous');
wait_for_ajax();
is(scalar @{$driver->find_elements('#job_next_previous_table tbody tr', 'css')},
    1, 'job next and previous of the latest job - 99981');

kill_driver();
done_testing();
