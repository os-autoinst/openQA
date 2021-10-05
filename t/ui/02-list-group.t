# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 04-products.pl');

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');
driver_missing unless my $driver = call_driver;

ok $driver->get('/tests?groupid=0'), 'list jobs without group';
wait_for_ajax(msg => 'wait for test list without group');
my @rows = $driver->find_child_elements($driver->find_element('#scheduled tbody'), 'tr');
is @rows, 1, 'one scheduled job without group';

ok $driver->get('/tests?groupid=1001'), 'list jobs with group 1001';
wait_for_ajax(msg => 'wait for test list with one group');
@rows = $driver->find_child_elements($driver->find_element('#running tbody'), 'tr');
is @rows, 1, 'one running job with this group';
ok $driver->find_element('#running #job_99963'), '99963 listed';

kill_driver;
done_testing;
