# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;

my $schema = OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 04-products.pl');

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');
driver_missing unless my $driver = call_driver;

subtest 'groupid' => sub {
    ok $driver->get('/tests?groupid=0'), 'list jobs without group';
    wait_for_ajax(msg => 'wait for test list without group');
    my @rows = $driver->find_child_elements($driver->find_element('#scheduled tbody'), 'tr');
    is @rows, 1, 'one scheduled job without group';

    ok $driver->get('/tests?groupid=1001'), 'list jobs with group 1001';
    wait_for_ajax(msg => 'wait for test list with one group');
    @rows = $driver->find_child_elements($driver->find_element('#running tbody'), 'tr');
    is @rows, 1, 'one running job with this group';
    ok $driver->find_element('#running #job_99963'), '99963 listed';
};

subtest 'group_glob and not_group_glob' => sub {
    $schema->resultset('JobGroups')->create($_)
      for (
        {
            id => 1003,
            sort_order => 0,
            name => 'opensuse development'
        },
        {
            id => 1004,
            sort_order => 0,
            name => 'Tumbleweed'
        },
        {
            id => 1005,
            sort_order => 0,
            name => 'SLE 15 SP5'
        },
        {
            id => 1006,
            sort_order => 0,
            name => 'SLE 15 SP5 development'
        });
    my $template = {
        state => 'done',
        result => 'passed',
        TEST => "textmode",
        FLAVOR => 'DVD',
        DISTRI => 'opensuse',
        BUILD => '0091',
        VERSION => '13.1',
        MACHINE => '32bit',
        ARCH => 'i586'
    };
    $_->delete for $schema->resultset('Jobs')->all;
    $schema->resultset('Jobs')->create($_)
      for (
        {
            %$template,
            id => 99951,
            group_id => 1003
        },
        {
            %$template,
            id => 99952,
            group_id => 1004
        },
        {
            %$template,
            id => 99953,
            group_id => 1005
        },
        {
            %$template,
            id => 99954,
            group_id => 1006
        });

    subtest 'no group filter' => sub {
        ok $driver->get('/tests'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 4, 'four jobs';
        ok $driver->find_element('#results #job_99951'), '99951 listed';
        ok $driver->find_element('#results #job_99952'), '99952 listed';
        ok $driver->find_element('#results #job_99953'), '99953 listed';
        ok $driver->find_element('#results #job_99954'), '99954 listed';
    };

    subtest 'filter with glob include' => sub {
        ok $driver->get('/tests?group_glob=*SLE*'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 2, 'two jobs';
        ok $driver->find_element('#results #job_99953'), '99953 listed';
        ok $driver->find_element('#results #job_99954'), '99954 listed';
    };

    subtest 'filter with multiple glob includes' => sub {
        ok $driver->get('/tests?group_glob=*SLE*,Tumbleweed'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 3, 'three jobs';
        ok $driver->find_element('#results #job_99952'), '99952 listed';
        ok $driver->find_element('#results #job_99953'), '99953 listed';
        ok $driver->find_element('#results #job_99954'), '99954 listed';
    };

    subtest 'filter with exact exclude' => sub {
        ok $driver->get('/tests?not_group_glob=Tumbleweed'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 3, 'three jobs';
        ok $driver->find_element('#results #job_99951'), '99951 listed';
        ok $driver->find_element('#results #job_99953'), '99953 listed';
        ok $driver->find_element('#results #job_99954'), '99954 listed';
    };

    subtest 'filter with glob exclude' => sub {
        ok $driver->get('/tests?not_group_glob=*SLE*'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 2, 'two jobs';
        ok $driver->find_element('#results #job_99951'), '99951 listed';
        ok $driver->find_element('#results #job_99952'), '99952 listed';
    };

    subtest 'filter with glob include and exclude' => sub {
        ok $driver->get('/tests?group_glob=*opensuse*,*SLE*&not_group_glob=*development*'), 'list jobs';
        wait_for_ajax(msg => 'wait for test list');
        my @rows = $driver->find_child_elements($driver->find_element('#results tbody'), 'tr');
        is @rows, 1, 'one job';
        ok $driver->find_element('#results #job_99953'), '99953 listed';
    };
};

kill_driver;
done_testing;
