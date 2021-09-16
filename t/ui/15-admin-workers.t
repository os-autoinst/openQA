#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Constants 'DEFAULT_WORKER_TIMEOUT';
use OpenQA::Test::TimeLimit '18';
use OpenQA::Test::Case;
use OpenQA::Test::Utils qw(assume_all_assets_exist embed_server_for_testing);
use Date::Format 'time2str';
use OpenQA::WebSockets::Client;
use OpenQA::SeleniumTest;

my $broken_worker_id = 5;
my $online_worker_id = 6;
my $offline_worker_id = 8;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema
  = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
assume_all_assets_exist;

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client => OpenQA::WebSockets::Client->singleton,
);

my $jobs = $schema->resultset('Jobs');
my $workers = $schema->resultset('Workers');
$jobs->search({id => {-in => [99926, 99961]}})->update({assigned_worker_id => 1});
$workers->create(
    {
        id => $broken_worker_id,
        host => 'foo',
        instance => 42,
        error => 'out of order',
    });

# ensure workers are not considered dead too soon
my $online_timestamp = time2str('%Y-%m-%d %H:%M:%S', time + 7200, 'UTC');
$workers->update({t_seen => $online_timestamp});

my $offline_timestamp = time2str('%Y-%m-%d %H:%M:%S', time - DEFAULT_WORKER_TIMEOUT - 1, 'UTC');
$workers->create({id => $online_worker_id, host => 'online_test', instance => 1, t_seen => $online_timestamp});
$workers->create({id => $offline_worker_id, host => 'offline_test', instance => 1, t_seen => $offline_timestamp});

driver_missing unless my $driver = call_driver;

$driver->title_is("openQA", "on main page");

subtest 'offline status' => sub {
    $driver->get("/admin/workers/$offline_worker_id");
    like(
        $driver->find_element_by_class('status-info')->get_text,
        qr/Seen: .*ago.*Status: Offline$/s,
        'worker just shown as offline'
    );

    $workers->find($offline_worker_id)->update({error => 'graceful disconnect at foo', t_seen => $online_timestamp});
    $driver->get("/admin/workers/$offline_worker_id");
    like(
        $driver->find_element_by_class('status-info')->get_text,
        qr/Seen: foo.*Status: Offline \(graceful disconnect\)$/s,
        'worker shown as offline with graceful disconnect'
    );

    $workers->find($offline_worker_id)->update({t_seen => undef, error => undef});
    $driver->get("/admin/workers/$offline_worker_id");
    like(
        $driver->find_element_by_class('status-info')->get_text,
        qr/Seen: never.*Status: Offline$/s,
        'worker with t_seen not set yet shown as "never"'
    );
};

# without loggin we hide properties of worker
$driver->get('/admin/workers/1');
$driver->title_is('openQA: Worker localhost:1', 'on worker 1');
is(scalar @{$driver->find_elements('h3', 'css')}, 1, 'table properties hidden');

$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
# but ...

is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

subtest 'worker overview' => sub {
    $driver->find_element('#user-action a')->click();
    $driver->find_element_by_link_text('Workers')->click();
    $driver->title_is('openQA: Workers', 'on workers overview');
    $driver->find_element('#summary')->text_like(qr/Online: 4.*Idle: 1.*Total: 5/s, 'correct statistics');
    $driver->find_element('#workers_info')->text_like(qr/1 to 1 of 1.*filtered from 5 total/, 'correct number shown');

    # show all worker regardless of their state
    $driver->find_element_by_xpath("//select[\@id='workers_online']/option[1]")->click();

    # check delete link only shown on offline worker
    is($driver->find_element('tr#worker_1 .action')->get_text(), '', 'localhost:1 do not show delete button');
    is($driver->find_element('tr#worker_2 .action')->get_text(), '', 'remotehost:1 do not show delete button');
    is($driver->find_element("tr#worker_$broken_worker_id .action")->get_text(), '', 'foo do not show delete button');
    is($driver->find_element("tr#worker_$online_worker_id .action")->get_text(),
        '', 'online_test do not show delete button');
    is($driver->find_element("tr#worker_$offline_worker_id .action .btn")->is_displayed(),
        1, 'offline worker show delete button');

    # check worker 1
    is($driver->find_element('tr#worker_1 .worker')->get_text(), 'localhost:1', 'localhost:1 shown');
    $driver->find_element('tr#worker_1 .help_popover')->click();
    wait_for_element(selector => '.popover', description => 'worker status popover is displayed');
    wait_for_ajax;
    like($driver->find_element('.popover')->get_text(), qr/Worker status\nJob: 99963/, 'on 99963');

    # close the popover and wait until it is actually gone (seems to have a very short animation)
    $driver->find_element('.paginate_button')->click();
    wait_until_element_gone('.popover');

    # check worker 2
    is($driver->find_element('tr#worker_2 .worker')->get_text(), 'remotehost:1', 'remotehost:1 shown');
    disable_bootstrap_animations;
    $driver->find_element('tr#worker_2 .help_popover')->click();
    wait_for_element(selector => '.popover', description => 'worker status popover is displayed');
    like($driver->find_element('.popover')->get_text(), qr/Worker status\nJob: 99961/, 'working 99961');
    $driver->find_element('.paginate_button')->click();
    wait_until_element_gone('.popover');

    # check worker 3 (broken one added in schema hook)
    is($driver->find_element("tr#worker_$broken_worker_id .worker")->get_text(), 'foo:42', 'foo shown');
    $driver->find_element("tr#worker_$broken_worker_id .help_popover")->click();
    is(
        $driver->find_element("tr#worker_$broken_worker_id .status")->get_text(),
        'Broken', "worker $broken_worker_id is broken",
    );
    like($driver->find_element('.popover')->get_text(), qr/Error\nout of order/, 'reason for brokenness shown');
};

# test delete offline worker function
subtest 'delete offline worker' => sub {
    $driver->find_element("tr#worker_$offline_worker_id .btn")->click();
    my $e = wait_for_element(selector => 'div#flash-messages .alert span', description => 'delete message displayed');
    is($e->get_text(), 'Delete worker offline_test:1 successfully.', 'delete offline worker successfully');
    is(scalar @{$driver->find_elements('table#workers tbody tr')}, 4, 'worker deleted not shown');
};

$driver->find_element('tr#worker_1 .worker a')->click();
$driver->title_is('openQA: Worker localhost:1', 'on worker 1');
is(scalar @{$driver->find_elements('#content h3', 'css')}, 2, 'table properties shown');
like($driver->find_element_by_xpath('//body')->get_text(), qr/JOBTOKEN token99963/, 'token for 99963');

# previous jobs table
wait_for_ajax;
my $table = $driver->find_element_by_id('previous_jobs');
ok($table, 'previous jobs table found');
my @entries = map { $_->get_text() } $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is(scalar @entries, 6, 'two previous jobs shown (3 cols per row)');
is_deeply(
    \@entries,
    [
        'opensuse-13.1-NET-x86_64-Build0091-kde@64bit',
        '', 'not yet', 'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
        '0', 'about an hour ago',
    ],
    'correct entries shown'
);

# restart running job assigned to a worker
$driver->find_child_element($table, 'a.restart', 'css')->click();
wait_for_ajax;
$table = $driver->find_element_by_id('previous_jobs');
ok($table, 'still on same page (with table)');
@entries = map { $_->get_text() } $driver->find_child_elements($table, 'tbody/tr/td', 'xpath');
is_deeply(
    \@entries,
    [
        'opensuse-13.1-NET-x86_64-Build0091-kde@64bit (restarted)',
        '', 'not yet', 'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
        '0', 'about an hour ago',
    ],
    'the first job has been restarted'
);

kill_driver();
done_testing();
