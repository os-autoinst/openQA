#!/usr/bin/env perl
# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

# test jobtoken login is possible with correct jobtoken
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'token99963');
    });
$t->get_ok('/api/v1/whoami')->status_is(200)->json_is({'id' => 99963});

# test jobtoken login is not possible with wrong jobtoken
$t->ua->unsubscribe('start');
$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->add('X-API-JobToken' => 'wrongtoken');
    });
$t->get_ok('/api/v1/whoami')->status_is(403);

# and without jobtoken
$t->ua->unsubscribe('start');
$t->get_ok('/api/v1/whoami')->status_is(403);

done_testing();
