# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $jobs = $t->app->schema->resultset('Jobs');

$t->get_ok('/tests/overview/badge')->status_is(200)->content_type_is('image/svg+xml')->content_like(qr/running/);
$t->get_ok('/tests/overview/badge?result=passed')->status_is(200)->content_like(qr/passed/);
$t->get_ok('/tests/overview/badge?result=none&state=scheduled')->status_is(200)->content_like(qr/scheduled/);
$t->get_ok('/tests/overview/badge?build=87.5011')->status_is(200)->content_like(qr/not complete/);
$t->get_ok('/tests/overview/badge?build=0048')->status_is(200)->content_like(qr/failed/);
$t->get_ok('/tests/overview/badge?distri=nonexistent')->status_is(200)->content_like(qr/none/);
$t->get_ok('/tests/overview/badge?groupid=1001&build=0091')->status_is(200)->content_like(qr/running/);
$t->get_ok('/tests/overview/badge?build=0048&show_build=1')->status_is(200)->content_like(qr/0048: failed/);
$t->get_ok('/tests/overview/badge?build=0048&build=87.5011&show_build=1')->status_is(200)
  ->content_like(qr/multi: failed/);

subtest 'calculate_aggregate_status' => sub {
    is calculate_aggregate_status({}), NONE, 'empty hash returns none';
    is calculate_aggregate_status({passed => 5}), PASSED, 'only passed returns passed';
    is calculate_aggregate_status({passed => 3, softfailed => 1}), SOFTFAILED, 'softfailed beats passed';
    is calculate_aggregate_status({passed => 3, softfailed => 1, failed => 1}), FAILED,
      'failed beats softfailed and passed';
    is calculate_aggregate_status({passed => 3, unknown => 1}), FAILED, 'unknown counts as failed';
    is calculate_aggregate_status({passed => 3, failed => 1, not_complete => 1}), FAILED, 'failed beats not_complete';
    is calculate_aggregate_status({passed => 3, not_complete => 1}), 'not_complete',
      'not_complete beats softfailed/passed';
    is calculate_aggregate_status({passed => 3, aborted => 1}), ABORTED, 'aborted beats passed';
    is calculate_aggregate_status({passed => 3, cancelled => 1}), CANCELLED, 'cancelled beats passed';
    is calculate_aggregate_status({passed => 3, softfailed => 1, failed => 1, scheduled => 1}), SCHEDULED,
      'scheduled beats failed/softfailed/passed';
    is calculate_aggregate_status({passed => 3, softfailed => 1, failed => 1, scheduled => 1, running => 1}),
      RUNNING, 'running beats scheduled/failed/softfailed/passed';
};

subtest 'overview badge priorities' => sub {
    $t->get_ok('/tests/overview/badge?build=0048')->status_is(200);
    $t->content_like(qr/failed/, 'badge for build 0048 is initially failed due to job 99937');

    my @params = (
        BUILD => '0048',
        ARCH => 'x86_64',
        MACHINE => '64bit',
        DISTRI => 'opensuse',
        VERSION => 'Factory',
        FLAVOR => 'DVD'
    );
    my $sched = $jobs->create({@params, state => SCHEDULED, TEST => 'sched_test_badge'});
    $t->get_ok('/tests/overview/badge?build=0048')->status_is(200);
    $t->content_like(qr/scheduled/, 'badge becomes scheduled when new job is scheduled');

    my $run = $jobs->create({@params, state => RUNNING, TEST => 'running_test_badge'});
    $t->get_ok('/tests/overview/badge?build=0048')->status_is(200);
    $t->content_like(qr/running/, 'badge becomes running when running job added');
};

subtest 'svg badge' => sub {
    $t->get_ok('/tests/99927/badge')->status_is(200)->content_type_is('image/svg+xml')
      ->header_is('Cache-Control' => 'max-age=0, no-cache')->element_exists('svg', 'valid svg badge');
    $t->get_ok('/tests/9992711111/badge')->status_is(404)->content_type_is('image/svg+xml')->element_exists('svg')
      ->content_like(qr/404/, 'valid 404 svg badge');
    $t->get_ok('/tests/latest/badge?test=kde&machine=64bit')->status_is(200)->content_type_is('image/svg+xml')
      ->element_exists('svg', 'valid latest svg badge')->content_like(qr/running/);
    $t->get_ok('/tests/latest/badge?test=kde&machine=64bit&result=passed')->status_is(404);
    $jobs->find(99963)->update({result => FAILED, state => DONE});
    $jobs->find(99962)->update({result => PASSED, state => DONE});
    $t->get_ok('/tests/latest/badge?test=kde&machine=64bit&result=passed')->status_is(200)->content_like(qr/passed/);
    $t->get_ok('/tests/latest/badge?test=kde&machine=64bit')->status_is(200)->content_like(qr/failed/);
    $jobs->find(99928)->update({state => SCHEDULED, result => NONE, blocked_by_id => 99927});
    $t->get_ok('/tests/99928/badge')->status_is(200)->content_type_is('image/svg+xml')->element_exists('svg')
      ->content_like(qr/blocked/, 'valid blocked svg badge');

    $t->get_ok('/tests/99928/badge?label=CustomLabel')->status_is(200)->content_like(qr/CustomLabel/);
    $t->get_ok('/tests/99928/badge?label=CustomLabel')->status_is(200)->content_unlike(qr/path2/);
    $t->get_ok('/tests/99928/badge')->status_is(200)->content_like(qr/path2/);
};

done_testing;
