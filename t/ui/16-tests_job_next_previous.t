# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use Date::Format 'time2str';

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl 05-job_modules.pl 07-needles.pl'
);

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub prepare_database {
    my $jobs = $schema->resultset('Jobs');

    # Populate more jobs to test page setting and include incompletes
    for my $n (1 .. 15) {
        my $result = $n < 8 ? 'passed' : 'incomplete';
        my $new = {
            id => 99900 + $n,
            group_id => 1001,
            priority => 35,
            result => $result,
            state => "done",
            t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 18000, 'UTC'),
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            TEST => "textmode",
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

    # Create bug reference
    $schema->resultset('Comments')->create(
        {
            job_id => 99981,
            user_id => 99901,
            text => 'boo#1138417',
        });
    $schema->resultset('Bugs')->create(
        {
            bugid => 'boo#1138417',
            title => 'some title with "quotes" and <html>elements</html>',
            existing => 1,
            refreshed => 1,
        });
}

prepare_database;

driver_missing unless my $driver = call_driver;
disable_timeout;

sub goto_next_previous_tab {
    $driver->find_element('#nav-item-for-next_previous')->click();
    wait_for_element(selector => '.dataTables_wrapper');
    wait_for_ajax(msg => 'Next & previous table ready');
}

# check job next and previous not loaded when open tests/x
$t->get_ok('/tests/99946')->status_is(200)->element_exists_not(
    '#job_next_previous_table_wrapper .dataTables_wrapper',
    'datatable of job next and previous not loaded when open tests/x'
);

my $job_header = $t->tx->res->dom->at('#next_previous #scenario .h5');
like(
    OpenQA::Test::Case::trim_whitespace($job_header->all_text),
    qr/Next & previous results for opensuse-13\.1-DVD-i586-textmode/,
    'header for job scenario'
);

# trigger job next and previous for current job
$driver->title_is('openQA', 'on main page');
$driver->find_element_by_link_text('All Tests')->click();
wait_for_ajax(msg => 'wait for All Tests displayed before looking for 99946');
wait_for_element(selector => '[href="/tests/99946"]')->click();
goto_next_previous_tab;

# check job next and previous for current job
my ($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99946');
my $job99946 = $driver->find_element('#job_next_previous_table #job_result_99946');
my @tds = $driver->find_child_elements($job99946, 'td');
is((shift @tds)->get_text(), 'C', '99946 is current job');
is((shift @tds)->get_text(), 'zypper_up', 'failed module of 99946');
is((shift @tds)->get_text(), '0091', 'build of 99946 is 0091');
is((shift @tds)->get_text(), 'about 3 hours ago ( 01:00 hours )', 'finished and duration of 99946');

my $job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'L', '99947 is the latest job');
my $state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed', 'the latest job 99947 was passed');
is((shift @tds)->get_text(), '0092', 'build of 99947 is 0092');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99945')},
    1, 'found nearest previous job 99945');
is(scalar @{$driver->find_elements("//*[\@title='Done: incomplete']", 'xpath')}, 6, 'include 6 incomletes in page 1');
$driver->find_element_by_link_text('Next')->click();
is(scalar @{$driver->find_elements("//*[\@title='Done: incomplete']", 'xpath')}, 2, 'include 2 incomletes in page 2');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99901')},
    1, 'found farmost previous job 99901');

# select the most previous job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99901"]')->click();
goto_next_previous_tab;

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99901');
my $init_page = $driver->find_element_by_xpath("//*[\@class='paginate_button page-item active']")->get_text();
is($init_page, 2, 'init page is 2 for 99901');
my $job99901 = $driver->find_element('#job_next_previous_table #job_result_99901');
@tds = $driver->find_child_elements($job99901, 'td');
is((shift @tds)->get_text(), 'C', '99901 is current job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed', 'the latest job 99901 was passed');
is((shift @tds)->get_text(), '0091', 'build of 99901 is 0091');
is((shift @tds)->get_text(), 'about 4 hours ago ( 01:00 hours )', 'finished and duration of 99901');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99902')}, 1, 'found nearest next job 99902');
$driver->find_element_by_link_text('Previous')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')}, 1, 'found farmost next job 99946');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99947')}, 1,
    'found next and latest job 99947');

# select the latest job in the table and check its job next and previous results
$driver->find_element('[href="/tests/99947"]')->click();
goto_next_previous_tab;

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 19, '19 entries found for 99947');
$job99947 = $driver->find_element('#job_next_previous_table #job_result_99947');
@tds = $driver->find_child_elements($job99947, 'td');
is((shift @tds)->get_text(), 'C&L', '99947 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'Done: passed', 'the latest job 99947 was passed');
is((shift @tds)->get_text(), '0092', 'build of 99947 is 0092');
is((shift @tds)->get_text(), 'about 2 hours ago ( 01:58 hours )', 'finished and duration of 99947');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99946')},
    1, 'found nearest previous job 99946');
$driver->find_element_by_link_text('Next')->click();
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99901')},
    1, 'found farmost previous job 99901');

#check build links to overview page
$driver->find_element_by_link_text('0091')->click();
like(
    $driver->find_element('#summary .card-header')->get_text(),
    qr/Overall Summary of opensuse 13\.1 build 0091/,
    'build links to overview page'
);

# check job next and previous of current running/scheduled job
$driver->find_element_by_link_text('All Tests')->click();
wait_for_ajax(msg => 'wait for All Tests displayed before looking for 99963');
$driver->find_element('[href="/tests/99963"]')->click();
goto_next_previous_tab;

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 2, '2 entries found for 99963');
my $job99963 = $driver->find_element('#job_next_previous_table #job_result_99963');
@tds = $driver->find_child_elements($job99963, 'td');
is((shift @tds)->get_text(), 'C&L', '99963 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'running', 'job 99963 was running');
is((shift @tds)->get_text(), '0091', 'build of 99963 is 0091');
is((shift @tds)->get_text(), 'Not yet: running', '99963 is not yet finished');
is(scalar @{$driver->find_elements('#job_next_previous_table #job_result_99962')}, 1, 'found previous job 99962');

$driver->find_element_by_link_text('All Tests')->click();
wait_for_ajax(msg => 'wait for All Tests displayed before looking for 99928');
$driver->find_element('[href="/tests/99928"]')->click();
goto_next_previous_tab;

($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 1, '1 entries found for 99928');
my $job99928 = $driver->find_element('#job_next_previous_table #job_result_99928');
@tds = $driver->find_child_elements($job99928, 'td');
is((shift @tds)->get_text(), 'C&L', '99928 is current and the latest job');
$state = $driver->find_child_element(shift @tds, '.status', 'css');
is($state->get_attribute('title'), 'scheduled', 'job 99928 was scheduled');
is((shift @tds)->get_text(), '0091', 'build of 99928 is 0091');
is((shift @tds)->get_text(), 'Not yet: scheduled', '99928 is not yet finished');

# check job next and previous under tests/latest route
$driver->get('/tests/latest');
goto_next_previous_tab;
($entries) = $driver->get_text('#job_next_previous_table_info') =~ /of (\d+) entries$/;
is($entries, 1, '1 entries found for 99981');
my $job99981 = $driver->find_element('#job_next_previous_table #job_result_99981');
@tds = $driver->find_child_elements($job99981, 'td');
is((shift @tds)->get_text(), 'C&L', '99981 is current and the latest job');

# check job next and previous with scenario latest url
$driver->get('/tests/99945');
goto_next_previous_tab;
$driver->find_element_by_link_text('latest job for this scenario')->click();
my $scenario_latest_url = $driver->get_current_url();
like($scenario_latest_url, qr/latest?/, 'latest scenario URL includes latest');
like($scenario_latest_url, qr/arch=i586/, 'latest scenario URL includes architecture');
like($scenario_latest_url, qr/flavor=DVD/, 'latest scenario URL includes flavour');
like($scenario_latest_url, qr/test=textmode/, 'latest scenario URL includes test');
like($scenario_latest_url, qr/version=13.1/, 'latest scenario URL includes version');
like($scenario_latest_url, qr/machine=32bit/, 'latest scenario URL includes machine');
like($scenario_latest_url, qr/distri=opensuse/, 'latest scenario URL includes distri');
goto_next_previous_tab;
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
is($init_page, 2, 'init page is 2 for 99901');
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

subtest 'bug reference shown' => sub {
    my @bug_labels = $driver->find_elements('#bug-99981 .label_bug');
    is(scalar @bug_labels, 1, 'one bug label present');
    is(
        $bug_labels[0]->get_attribute('title'),
        "Bug referenced: boo#1138417\nsome title with \"quotes\" and <html>elements</html>",
        'title rendered with new-line, HTML code is rendered as text'
    );
};

kill_driver();
done_testing();
