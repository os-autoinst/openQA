#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Time::Seconds;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use DateTime;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::WebSockets;

my $schema = OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl');
$schema->resultset('Jobs')->search({id => 99963})->update({assigned_worker_id => 1});
$schema->resultset('Jobs')->create(
    {
        state => 'scheduled',
        priority => 50,
        TEST => 'no_arch_test',
        ARCH => '',
        DISTRI => 'opensuse',
        VERSION => '13.1',
        FLAVOR => 'DVD',
        MACHINE => '64bit',
    });
my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{global}->{base_url} = 'http://example.com';


$t->get_ok('/admin/influxdb/jobs')->status_is(200)->content_is(
    'openqa_jobs,url=http://example.com blocked=0i,running=2i,scheduled=3i
openqa_jobs_by_group,url=http://example.com,group=No\\ Group scheduled=2i
openqa_jobs_by_group,url=http://example.com,group=opensuse running=1i,scheduled=1i
openqa_jobs_by_group,url=http://example.com,group=opensuse\\ test running=1i
openqa_jobs_by_worker,url=http://example.com,worker=localhost running=1i
openqa_jobs_by_arch,url=http://example.com,arch=i586 scheduled=2i
openqa_jobs_by_arch,url=http://example.com,arch=x86_64 running=2i
'
)->content_unlike(qr/,arch= /);

$t->get_ok('/admin/influxdb/minion')->status_is(200)
  ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=0i,failed=0i,inactive=0i!)
  ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
  ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=0i,registered=0i!);
$t->app->minion->add_task(test => sub { });
my $job_id = $t->app->minion->enqueue('test');
my $job_id2 = $t->app->minion->enqueue('test');
my $worker = $t->app->minion->worker->register;
my $job = $worker->dequeue(0);
$t->get_ok('/admin/influxdb/minion')->status_is(200)
  ->content_like(qr!openqa_minion_jobs,url=http://example.com active=1i,delayed=0i,failed=0i,inactive=1i!)
  ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
  ->content_like(qr!openqa_minion_workers,url=http://example.com active=1i,inactive=0i,registered=1i!);
$job->fail('test');
$t->get_ok('/admin/influxdb/minion')->status_is(200)
  ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=0i,failed=1i,inactive=1i!)
  ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
  ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=1i,registered=1i!);
$t->get_ok('/admin/influxdb/minion?rc_fail_timespan_minutes=23')->status_is(200)
  ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_23min=0i \d+!);
$job->retry({delay => ONE_HOUR});
$t->get_ok('/admin/influxdb/minion')->status_is(200)
  ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=0i,inactive=2i!)
  ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
  ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=1i,registered=1i!);

subtest 'openqa_minion_jobs_hook_rc_failed counter' => sub {
    my $dbh = $schema->storage->dbh;
    my $static_now = DateTime->from_epoch(epoch => 3947);    # 1970-01-01T01:05:47
    my $rc_fail_finished = DateTime->from_epoch(epoch => 3521);    # 1970-01-01T00:46:57
    my $sth = $dbh->prepare(
q!INSERT INTO minion_jobs (id, args, created, delayed, finished, priority, result, retried, retries, started, state, task, worker, queue, attempts, parents, notes)
		VALUES (7291599, '["/bin/true", 11201356, {"delay": 60, "retries": 1440, "skip_rc": 142, "timeout": "10m", "kill_timeout": "10s"}]', '2023-05-26 17:00:50.542916+02', '2023-05-26 17:00:50.542916+02', ?, 0, null, null, 0, '2023-05-26 17:00:50.565839+02', 'finished', 'hook_script', 1388, 'default', 1, '{}', '{"hook_rc": -1, "hook_cmd": "foobar", "hook_result": "Job is '':investigate:'' already, skipping investigation\n"}')!
    );
    $sth->execute("$rc_fail_finished+0");
    my $mock_dt = Test::MockModule->new('DateTime');
    $mock_dt->mock(now => sub { $static_now->clone });
    $t->get_ok('/admin/influxdb/minion')->status_is(200)
      ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=0i,inactive=2i!)
      ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=1i 3600000000000!)
      ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=1i,registered=1i!);
    $sth = $dbh->prepare('DELETE FROM minion_jobs WHERE id = 7291599');
    $sth->execute();
};

subtest 'input validation' => sub {
    $t->get_ok('/admin/influxdb/minion?rc_fail_timespan_minutes=blub')->status_is(400)
      ->json_is({error => 'Erroneous parameters (rc_fail_timespan_minutes invalid)'});
};

subtest 'filter specified minion tasks' => sub {
    for my $task (qw(obs_rsync_run obs_rsync_update_builds_text)) {
        $t->app->minion->add_task($task => sub { });
        my $job_ids = $t->app->minion->enqueue($task);
    }
    while (my $tmp_job = $worker->dequeue(0)) { $tmp_job->fail('this is a test'); }

    $t->get_ok('/admin/influxdb/minion')->status_is(200)
      ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=3i,inactive=1i!)
      ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
      ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=1i,registered=1i!);

    # Define the filter list, so failed jobs for blocklisted tasks will not be
    # counted towards the total of failed jobs, i.e. failed=1i instead of failed=3i
    $t->app->config->{influxdb}->{ignored_failed_minion_jobs} = ['obs_rsync_run', 'obs_rsync_update_builds_text'];
    $t->get_ok('/admin/influxdb/minion')->status_is(200)
      ->content_like(qr!openqa_minion_jobs,url=http://example.com active=0i,delayed=1i,failed=1i,inactive=1i!)
      ->content_like(qr!openqa_minion_jobs_hook_rc_failed,url=http://example.com rc_failed_per_10min=0i \d+!)
      ->content_like(qr!openqa_minion_workers,url=http://example.com active=0i,inactive=1i,registered=1i!);
};

$worker->unregister;

subtest 'job impact influxdb metrics' => sub {
    my $job = $schema->resultset('Jobs')->find(99926);
    $job->update({t_finished => DateTime->now(time_zone => 'UTC')});
    my $impact = $job->create_related(
        'impact',
        {
            seconds => 1800,
            vcpus => 2,
            ram_gb => 4,
            power_w => 50,
            energy_kwh => 0.0375,
            carbon_g => 12.5,
            cost_energy => 0.0075,
            cost_hardware => 0.005,
            cost_total => 0.0125,
            currency => 'EUR',
            model_version => 1,
            factors => {},
        });

    $t->get_ok('/admin/influxdb/jobs')->status_is(200)
      ->content_like(
qr/openqa_job_impact,url=http:\/\/example\.com,group=\S+,origin=\S+ jobs=\d+i,seconds=\d+i,energy_kwh=[\d\.]+,carbon_g=[\d\.]+,cost_total=[\d\.]+/
      );

    {
        local $t->app->config->{job_impact}->{enabled} = 0;
        $t->get_ok('/admin/influxdb/jobs')->status_is(200)->content_unlike(qr/openqa_job_impact/);
    }

    $impact->delete;
};

done_testing();
