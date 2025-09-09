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

subtest jobs => sub {
    $t->get_ok('/api/v1/jobs/23')->status_is(404)->json_is('/error', 'Job does not exist');
    $t->get_ok('/api/v1/jobs/23a')->status_is(400)
      ->json_like('/details/jobid/message', qr{Expected integer - got string})
      ->json_like('/error', qr{Erroneous.*Expected integer - got string});

    $t->get_ok('/api/v1/jobs/80000')->status_is(200)->json_is('/job/id', '80000')->json_is('/job/testresults', undef)
      ->json_is('/job/priority', 50);
    $t->get_ok('/api/v1/jobs/80000/details')->status_is(200)->json_is('/job/id', '80000')
      ->json_is('/job/testresults', []);
    $t->get_ok('/api/v1/jobs/99945?follow=1')->status_is(200)->json_is('/job/id', '99946');
    $t->get_ok('/api/v1/jobs/99945?follow=2')->status_is(400)
      ->json_like('/details/follow/message', qr{Not in enum list});

    $t->post_ok('/api/v1/jobs/80000/prio', form => {prio => 99})->status_is(200);
    $t->post_ok('/api/v1/jobs/80000/prio', form => {prio => 'not a number'})->status_is(400)
      ->json_like('/details/body_prio/message', qr{Expected integer - got string});
};

done_testing;
