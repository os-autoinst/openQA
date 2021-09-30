#!/usr/bin/env perl

# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use DateTime;
use Test::Warnings ':report_warnings';
use Test::Output qw(combined_like stderr_like);
use OpenQA::App;
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(redirect_output);
use OpenQA::Test::TimeLimit '10';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl 06-job_dependencies.pl');
my $jobs = $schema->resultset('Jobs');
$jobs->find(99963)->update({assigned_worker_id => 1});
$jobs->find(99961)->update({assigned_worker_id => 2});
$jobs->find(80000)->update({state => ASSIGNED, result => NONE, assigned_worker_id => 1});

OpenQA::App->set_singleton(my $app = OpenQA::Scheduler->new);
$app->setup;
$app->log(undef);

subtest 'worker with job and not updated in last 120s is considered dead' => sub {
    my $dtf = $schema->storage->datetime_parser;
    my $dt = DateTime->from_epoch(epoch => time(), time_zone => 'UTC');
    my $workers = $schema->resultset('Workers');
    my $jobs = $jobs;
    $workers->update_all({t_seen => $dtf->format_datetime($dt)});
    is($jobs->stale_ones->count, 0, 'job not considered stale if recently seen');
    $dt->subtract(seconds => DEFAULT_WORKER_TIMEOUT + DB_TIMESTAMP_ACCURACY);
    $workers->update_all({t_seen => $dtf->format_datetime($dt)});
    is($jobs->stale_ones->count, 3, 'jobs considered stale if t_seen exceeds the timeout');
    $workers->update_all({t_seen => undef});
    is($jobs->stale_ones->count, 3, 'jobs considered stale if t_seen is not set');

    stderr_like { OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs }
    qr/Dead job 99961 aborted and duplicated 99982\n.*Dead job 99963 aborted as incomplete/, 'dead jobs logged';

    for my $job_id (99961, 99963) {
        my $job = $jobs->find(99963);
        is($job->state, DONE, "running job $job_id is now done");
        is($job->result, INCOMPLETE, "running job $job_id has been marked as incomplete");
        isnt($job->clone_id, undef, "running job $job_id a clone");
        like(
            $job->reason,
            qr/abandoned: associated worker (remote|local)host:1 has not sent any status updates for too long/,
            "job $job_id set as incomplete"
        );
    }

    my $assigned_job = $jobs->find(80000);
    is($assigned_job->state, SCHEDULED, 'assigned job not done');
    is($assigned_job->result, NONE, 'assigned job has been re-scheduled');
    is($assigned_job->clone_id, undef, 'assigned job has not been cloned');
    is($assigned_job->assigned_worker_id, undef, 'assigned job has no worker assigned');

    is($app->minion->jobs({tasks => ['finalize_job_results']})->total,
        2, 'minion job to finalize incomplete jobs enqueued');
};

subtest 'exception during stale job detection handled and logged' => sub {
    my $mock_schema = Test::MockModule->new('OpenQA::Schema');
    my $mock_singleton_called;
    $mock_schema->redefine(singleton => sub { $mock_singleton_called++; bless({}); });
    combined_like { OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs }
    qr/Failed stale job detection/, 'failure logged';
    ok($mock_singleton_called, 'mocked singleton method has been called');
};

done_testing();

1;
