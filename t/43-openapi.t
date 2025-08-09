# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later.

use Test::Most;
use Test::Warnings qw(:report_warnings);
use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->log->level('trace');
$t->get_ok('/api/v1/jobs/23')->status_is(404)->json_is('/error', 'Job does not exist');
$t->get_ok('/api/v1/jobs/80000')->status_is(200)
    ->json_is('/job/id', '80000')
    ->json_is('/job/testresults', undef);
$t->get_ok('/api/v1/jobs/80000/details')->status_is(200)
    ->json_is('/job/id', '80000')
    ->json_is('/job/testresults', []);

$t->get_ok('/api/v1/job_groups/23')->status_is(404)->json_is('/error', 'Group 23 does not exist');
$t->get_ok('/api/v1/job_groups/1001')->status_is(200)->json_is('/0/id', '1001');

done_testing;
