# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use Math::BigInt;
use OpenQA::Constants qw(MAX_BIGINT);

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest '404 error page' => sub {
    $t->get_ok('/unavailable_page')->status_is(404);
    my $dom = $t->tx->res->dom;
    is_deeply([$dom->find('h1')->map('text')->each], ['Page not found'], 'correct page');
    is_deeply([$dom->find('h2')->map('text')->each], ['Available routes'], 'available routes shown');
    ok(index($t->tx->res->text, 'Each entry contains the') >= 0, 'description shown');
};

subtest 'error pages shown for OpenQA::WebAPI::Controller::Step' => sub {
    my $existing_job = 99946;
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1")->status_is(302, 'redirection');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1", {'X-Requested-With' => 'XMLHttpRequest'})
      ->status_is(200);
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/src")->status_is(200)
      ->content_type_is('text/html;charset=UTF-8');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/src.txt")->status_is(200)
      ->content_type_is('text/plain;charset=UTF-8');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/edit")->status_is(200);

    subtest 'get error 404 if job or module not found' => sub {
        my $non_existing_job = 99999;
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1")->status_is(302, 'redirection');
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1",
            {'X-Requested-With' => 'XMLHttpRequest'})->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/src")->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/src.txt")->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/edit")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/src")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/src.txt")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/edit")->status_is(404);
    };
};

subtest '404 pages for out of range integers' => sub {
    # avoid formatting like 9.22337203685478e+18
    my $big = Math::BigInt->new(MAX_BIGINT + 1);
    my @routes = (
        '/group_overview/ID', '/tests/ID',
        '/tID', '/tests/ID/details_ajax',
        '/tests/ID/status', '/needles/ID/image',
        '/parent_group_overview/ID', '/admin/job_templates/ID',
        '/api/v1/machines/ID'
    );
    for my $route (@routes) {
        $t->get_ok($route =~ s/ID/$big/r)->status_is(404, $route);
    }
    $t->get_ok("/tests/80000/asset/$big")->status_is(404);
    $t->get_ok("/tests/$big/asset/$big")->status_is(404);
};


done_testing;
