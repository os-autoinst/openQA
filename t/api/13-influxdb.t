#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Time::Seconds;
use Test::Mojo;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::WebSockets;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{global}->{base_url} = 'http://example.com';

$t->get_ok('/admin/influxdb/jobs')->status_is(200)->content_is(
    "openqa_jobs,url=http://example.com blocked=0i,running=2i,scheduled=2i
openqa_jobs_by_group,url=http://example.com,group=No\\ Group scheduled=1i
openqa_jobs_by_group,url=http://example.com,group=opensuse running=1i,scheduled=1i
openqa_jobs_by_group,url=http://example.com,group=opensuse\\ test running=1i
openqa_jobs_by_arch,url=http://example.com,arch=i586 scheduled=2i
openqa_jobs_by_arch,url=http://example.com,arch=x86_64 running=2i
"
);

$t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
    "openqa_minion_jobs,url=http://example.com active=0i,delayed=0i,failed=0i,inactive=0i
openqa_minion_workers,url=http://example.com active=0i,inactive=0i
"
);
$t->app->minion->add_task(test => sub { });
my $job_id = $t->app->minion->enqueue('test');
my $job_id2 = $t->app->minion->enqueue('test');
my $worker = $t->app->minion->worker->register;
my $job = $worker->dequeue(0);
$t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
    "openqa_minion_jobs,url=http://example.com active=1i,delayed=0i,failed=0i,inactive=1i
openqa_minion_workers,url=http://example.com active=1i,inactive=0i
"
);
$job->fail('test');
$t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
    "openqa_minion_jobs,url=http://example.com active=0i,delayed=0i,failed=1i,inactive=1i
openqa_minion_workers,url=http://example.com active=0i,inactive=1i
"
);
$job->retry({delay => ONE_HOUR});
$t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
    "openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=0i,inactive=2i
openqa_minion_workers,url=http://example.com active=0i,inactive=1i
"
);

subtest 'filter specified minion tasks' => sub {
    for my $task (qw(obs_rsync_run obs_rsync_update_builds_text)) {
        $t->app->minion->add_task($task => sub { });
        my $job_ids = $t->app->minion->enqueue($task);
    }
    while (my $tmp_job = $worker->dequeue(0)) { $tmp_job->fail('this is a test'); }

    $t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
        "openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=3i,inactive=1i
openqa_minion_workers,url=http://example.com active=0i,inactive=1i
"
    );

    # Define the filter list, so failed jobs for blocklisted tasks will not be
    # counted towards the total of failed jobs, i.e. failed=1i instead of failed=3i
    $t->app->config->{influxdb}->{ignored_failed_minion_jobs} = ['obs_rsync_run', 'obs_rsync_update_builds_text'];
    $t->get_ok('/admin/influxdb/minion')->status_is(200)->content_is(
        "openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=1i,inactive=1i
openqa_minion_workers,url=http://example.com active=0i,inactive=1i
"
    );
};

$worker->unregister;

done_testing();
