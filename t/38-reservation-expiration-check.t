#!/usr/bin/env perl
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::WorkerReservation 'RESERVATION_PROPERTIES';
use OpenQA::Test::Utils qw(perform_minion_jobs);

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $db = $t->app->schema;
my $workers = $db->resultset('Workers');
my $users = $db->resultset('Users');

subtest 'check reservation expiration warning task' => sub {
    my $worker = $workers->first;
    my $operator = $users->find(99903);

    $worker->delete_properties([RESERVATION_PROPERTIES]);

    $worker->reserve($operator, 'short reservation', '1h');
    $worker->set_property(RESERVED_T_EXPIRES => time + 1200);

    my $minion = $t->app->minion;
    my $id = $minion->enqueue('check_reservation_expiration');
    ok defined $id, 'CheckExpiration background task can be enqueued';
    perform_minion_jobs($minion);

    my $job_info = $minion->job($id)->info;
    is $job_info->{state}, 'finished', 'CheckExpiration background task completes successfully';
    is $job_info->{result}->{notified}, 1, 'CheckExpiration background task detects exactly one expiring reservation';

    my $audit_events = $db->resultset('AuditEvents')->search({event => 'worker_reservation_expiring'});
    is $audit_events->count, 1, 'emits and logs a worker_reservation_expiring audit log event';
    like $audit_events->first->event_data, qr/short reservation/,
      'audit event payload includes comment of expiring reservation';
};

done_testing();
