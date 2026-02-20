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

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

$t->get_ok('/tests/overview/badge')->status_is(200)->content_type_is('image/svg+xml')->content_like(qr/running/);
$t->get_ok('/tests/overview/badge?result=passed')->status_is(200)->content_like(qr/passed/);
$t->get_ok('/tests/overview/badge?result=none&state=scheduled')->status_is(200)->content_like(qr/scheduled/);
$t->get_ok('/tests/overview/badge?build=87.5011')->status_is(200)->content_like(qr/not complete/);
$t->get_ok('/tests/overview/badge?build=0048')->status_is(200)->content_like(qr/failed/);
$t->get_ok('/tests/overview/badge?distri=nonexistent')->status_is(200)->content_like(qr/none/);
$t->get_ok('/tests/overview/badge?groupid=1001&build=0091')->status_is(200)->content_like(qr/running/);

done_testing;
