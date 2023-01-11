#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -strict, -signatures;
use Time::Seconds;
$ENV{MOJO_LOG_LEVEL} = 'info';

my $tempdir;
BEGIN {
    use Mojo::File qw(path tempdir);

    $ENV{OPENQA_CACHE_SERVICE_QUIET} = $ENV{HARNESS_IS_VERBOSE} ? 0 : 1;
    $ENV{OPENQA_CACHE_ATTEMPTS} = 3;
    $ENV{OPENQA_CACHE_ATTEMPT_SLEEP_TIME} = 0;
    $ENV{OPENQA_RSYNC_RETRY_PERIOD} = 0;
    $ENV{OPENQA_METRICS_DOWNLOAD_SIZE} = 1024;

    $tempdir = tempdir;
    my $basedir = $tempdir->child('t', 'cache.d');
    $ENV{OPENQA_CACHE_DIR} = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR} = $basedir;
    $ENV{OPENQA_CONFIG} = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt('
[global]
CACHEDIRECTORY = ' . $ENV{OPENQA_CACHE_DIR} . '
CACHEWORKERS = 10
CACHELIMIT = 100');
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::Warnings ':report_warnings';
use Test::Output qw(stderr_like);
use Test::Mojo;
use OpenQA::Utils;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils
  qw(fake_asset_server cache_minion_worker cache_worker_service wait_for_or_bail_out perform_minion_jobs);
use OpenQA::Test::TimeLimit '90';
use Mojo::Util qw(md5_sum);
use OpenQA::CacheService;
use OpenQA::CacheService::Request;
use OpenQA::CacheService::Client;
use Time::Seconds;

my $cachedir = $ENV{OPENQA_CACHE_DIR};
my $port = Mojo::IOLoop::Server->generate_port;
my $host = "http://localhost:$port";

my $cache_client = OpenQA::CacheService::Client->new();

END { session->clean }

my $cache_service = cache_worker_service;
my $t = Test::Mojo->new('OpenQA::CacheService');

my $server_instance = process sub {
    # Connect application with web server and start accepting connections
    my $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host])->silent(1);
    $daemon->run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);    # uncoverable statement to ensure proper exit code of complete test at cleanup
  },
  max_kill_attempts => 0,
  blocking_stop => 1,
  _default_blocking_signal => POSIX::SIGTERM,
  kill_sleeptime => 0;

sub start_servers () {
    $server_instance->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $cache_service->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    perform_minion_jobs($t->app->minion);
    wait_for_or_bail_out { $cache_client->info->available } 'cache service';
}

sub test_default_usage ($id, $asset) {
    my $asset_request = $cache_client->asset_request(id => $id, asset => $asset, type => 'hdd', host => $host);

    if (!$cache_client->enqueue($asset_request)) {
        perform_minion_jobs($t->app->minion);
        wait_for_or_bail_out { $cache_client->status($asset_request)->is_processed } 'asset';
    }
    ok($cache_client->asset_exists('localhost', $asset), "Asset $asset downloaded");
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

sub test_sync ($run) {
    my $dir = tempdir;
    my $dir2 = tempdir;
    my $rsync_request = $cache_client->rsync_request(from => $dir, to => $dir2);

    my $t_dir = int(rand(13432432));
    my $data = int(rand(348394280934820842093));
    $dir->child($t_dir)->spurt($data);
    my $expected = $dir2->child('tests')->child($t_dir);

    ok !$cache_client->enqueue($rsync_request);

    perform_minion_jobs($t->app->minion);
    wait_for_or_bail_out { $cache_client->status($rsync_request)->is_processed } 'rsync';

    my $status = $cache_client->status($rsync_request);
    is $status->result, 'exit code 0', "exit code ok, run $run";
    ok $status->output, "output ok, run $run";

    like $status->output, qr/Calling: rsync .* --timeout 1800 .*100\%/s, "output correct, run $run"
      or die diag $status->output;

    ok -e $expected, "expected file exists, run $run";
    is $expected->slurp, $data, "synced data identical, run $run";

    my $rsync_request2;
    stderr_like {
        $rsync_request2 = $cache_client->rsync_request(from => "empty", to => "nowhewre");
        ok !$cache_client->enqueue($rsync_request2);

        perform_minion_jobs($t->app->minion);
        wait_for_or_bail_out { $cache_client->status($rsync_request2)->is_processed } 'rsync';
    }
    qr/rsync error:.*/, "rsync error message";

    my $status2 = $cache_client->status($rsync_request2);
    is $status2->result, 'exit code 11', "exit code ok, run $run";
    ok $status2->output, "output ok, run $run";

    like $status2->output, qr/Calling: rsync .* --timeout 1800 .*/s, "output correct, run $run"
      or die diag $status2->output;
}

sub test_download ($id, $asset) {
    unlink path($cachedir)->child($asset);
    my $asset_request = $cache_client->asset_request(id => $id, asset => $asset, type => 'hdd', host => $host);

    ok !$cache_client->enqueue($asset_request), "enqueued id $id, asset $asset";

    my $status = $cache_client->status($asset_request);
    perform_minion_jobs($t->app->minion);
    $status = $cache_client->status($asset_request) until !$status->is_downloading;

    # And then goes to PROCESSED state
    ok $status->is_processed, 'only other state is processed';
    ok exists $status->data->{has_download_error}, 'whether a download error happened is added to status info';
    ok !$status->data->{has_download_error}, 'no download error occurred';

    ok($cache_client->asset_exists('localhost', $asset), "Asset downloaded id $id, asset $asset");
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

sub perform_job_in_foreground ($job) {
    if (my $err = $job->execute) { $job->fail($err) }
    else { $job->finish }
}

subtest 'OPENQA_CACHE_DIR environment variable' => sub {
    local $ENV{OPENQA_CACHE_DIR} = '/does/not/exist';
    my $client = OpenQA::CacheService::Client->new;
    is $client->cache_dir, '/does/not/exist', 'environment variable used';
};

subtest 'Availability check and worker status' => sub {
    my $info = OpenQA::CacheService::Response::Info->new(data => {}, error => 'foo');
    is($info->availability_error, 'foo', 'availability error');

    $info = OpenQA::CacheService::Response::Info->new(
        data => {active_workers => 0, inactive_workers => 0, inactive_jobs => 0},
        error => undef
    );
    is $info->availability_error, 'No workers active in the cache service', 'no workers active';

    $info = OpenQA::CacheService::Response::Info->new(
        data => {active_workers => 1, inactive_workers => 0, inactive_jobs => 6},
        error => undef
    );
    is $info->availability_error, 'Cache service queue already full (5)', 'cache service jobs pileup';

    $info = OpenQA::CacheService::Response::Info->new(
        data => {active_workers => 0, inactive_workers => 1, inactive_jobs => 3},
        error => undef
    );
    is $info->availability_error, undef, 'no error';
};

subtest 'Configurable minion workers' => sub {
    is_deeply([OpenQA::CacheService::setup_workers(qw(minion test))],
        [qw(minion test)], 'minion worker setup with test');
    is_deeply([OpenQA::CacheService::setup_workers(qw(run))], [qw(run -j 10)], 'minion worker setup with worker');
    is_deeply([OpenQA::CacheService::setup_workers(qw(minion daemon))],
        [qw(minion daemon)], 'minion worker setup with daemon');

    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("
[global]
CACHEDIRECTORY = $cachedir
CACHELIMIT = 100");

    is_deeply([OpenQA::CacheService::setup_workers(qw(run))], [qw(run -j 5)], 'minion worker setup with parallel jobs');
};

subtest 'Cache Requests' => sub {
    my $asset_request = $cache_client->asset_request(id => 922756, asset => 'test', type => 'hdd', host => 'open.qa');
    my $rsync_request = $cache_client->rsync_request(from => 'foo', to => 'bar');

    is $rsync_request->lock, join('.', 'foo', 'bar'), 'rsync request';
    is $asset_request->lock, join('.', 'test', 'open.qa'), 'asset request';

    is_deeply $rsync_request->to_array, [qw(foo bar)], 'rsync request array';
    is_deeply $asset_request->to_array, [qw(922756 hdd test open.qa)], 'asset request array';

    my $base = OpenQA::CacheService::Request->new;
    local $@;
    eval { $base->lock };
    like $@, qr/lock\(\) not implemented in OpenQA::CacheService::Request/, 'lock() not implemented in base request';
    eval { $base->to_array };
    like $@, qr/to_array\(\) not implemented in OpenQA::CacheService::Request/,
      'to_array() not implemented in base request';
};

start_servers;

subtest 'Invalid requests' => sub {
    my $url = $cache_client->url('/status/12345');
    my $invalid_request = $cache_client->ua->get($url);
    my $json = $invalid_request->result->json;
    is_deeply($json, {error => 'Specified job ID is invalid'}, 'invalid job ID') or diag explain $json;

    $url = $cache_client->url('/status/abc');
    $invalid_request = $cache_client->ua->get($url);
    is $invalid_request->res->code, 404, 'invalid job ID';

    $url = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {args => []});
    $json = $invalid_request->result->json;
    is_deeply($json, {error => 'No task defined'}, 'invalid task') or diag explain $json;

    $url = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {task => 'cache_asset'});
    $json = $invalid_request->result->json;
    is_deeply($json, {error => 'No arguments defined'}, 'invalid args') or diag explain $json;

    $url = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {task => 'cache_asset', args => []});
    $json = $invalid_request->result->json;
    is_deeply($json, {error => 'No lock defined'}, 'invalid lock') or diag explain $json;
};

subtest 'Asset exists' => sub {
    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent');
    path($cachedir, 'localhost')->make_path->child('foobar')->spurt('test');

    ok($cache_client->asset_exists('localhost', 'foobar'), 'Asset exists');
    unlink path($cachedir, 'localhost')->child('foobar')->to_string;
    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent')
      or die diag explain path($cachedir, 'localhost')->list_tree;

};

subtest 'Increased SQLite busy timeout' => sub {
    my $cache = $t->app;
    is $cache->cache->sqlite->db->dbh->sqlite_busy_timeout, 600000, '10 minute cache busy timeout';
    is $cache->minion->backend->sqlite->db->dbh->sqlite_busy_timeout, 600000, '10 minute minion busy timeout';
};

subtest 'Job progress (guard against parallel downloads of the same file)' => sub {
    my $app = $t->app;
    ok !$app->progress->is_downloading('foo'), 'not downloading';
    is $app->progress->downloading_job('foo'), undef, 'no job';
    my $guard = $app->progress->guard('foo', 123);
    ok $app->progress->is_downloading('foo'), 'is downloading';
    is $app->progress->downloading_job('foo'), 123, 'has job';
    ok $app->progress->is_downloading('foo'), 'still downloading';
    undef $guard;
    ok !$app->progress->is_downloading('foo'), 'not downloading anymore';

    $guard = $app->progress->guard('foo', 124);
    ok $app->progress->is_downloading('foo'), 'is downloading again';
    is $app->progress->downloading_job('foo'), 124, 'new job';
    undef $guard;
    $guard = $app->progress->guard('foo', 125);
    ok $app->progress->is_downloading('foo'), 'is downloading again for 125';
    is $app->progress->downloading_job('foo'), 125, 'new job 125';
    undef $guard;

    my $db = $app->downloads->cache->sqlite->db;
    is $db->select('downloads', '*', {lock => 'foo'})->hashes->size, 3, 'three entries';
    $db->update('downloads', {created => \'datetime(\'now\',\'-3 day\')'});
    $guard = $app->progress->guard('foo', 126);
    ok $app->progress->is_downloading('foo'), 'is downloading again for 126';
    is $app->progress->downloading_job('foo'), 126, 'new job 126';
    is $db->select('downloads', '*', {lock => 'foo'})->hashes->size, 1, 'old jobs have been removed';
};

subtest 'Client can check if there are available workers' => sub {
    $cache_service->stop;
    ok !$cache_client->info->available, 'Cache server is not available';
    $cache_service->restart;
    perform_minion_jobs($t->app->minion);
    wait_for_or_bail_out { $cache_client->info->available } 'cache service';
    ok $cache_client->info->available, 'Cache server is available';
    ok !$cache_client->info->available_workers, 'No available workers at the moment';
    perform_minion_jobs($t->app->minion);
    my $worker = $t->app->minion->worker->register;
    wait_for_or_bail_out { $cache_client->info->available_workers } 'minion_worker';
    ok $cache_client->info->available_workers, 'Workers are available now';
    $worker->unregister;
};

subtest 'Asset download' => sub {
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_2900@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2');
};

subtest 'Race for same asset' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2';

    my $asset_request = $cache_client->asset_request(id => 922756, asset => $asset, type => 'hdd', host => $host);

    my $sum = md5_sum(path($cachedir, 'localhost')->child($asset)->slurp);
    unlink path($cachedir, 'localhost')->child($asset)->to_string;
    ok(!$cache_client->asset_exists('localhost', $asset), 'Asset absent')
      or die diag "Asset already exists - abort test";

    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 3;
    my $concurrent = $ENV{STRESS_TEST} ? 30 : 2;
    my $q = queue;
    $q->pool->maximum_processes($concurrent);
    $q->queue->maximum_processes($tot_proc);

    my $concurrent_test = sub {
        if (!$cache_client->enqueue($asset_request)) {
            perform_minion_jobs($t->app->minion);
            wait_for_or_bail_out { $cache_client->status($asset_request)->is_processed } 'asset';
            my $ret = $cache_client->asset_exists('localhost', $asset);
            Devel::Cover::report() if Devel::Cover->can('report');
            return $ret;    # uncoverable statement
        }
    };

    $q->add(process($concurrent_test)->set_pipes(0)->internal_pipes(1)) for 1 .. $tot_proc;

    $q->consume();
    is $q->done->size, $tot_proc, 'Queue consumed ' . $tot_proc . ' processes';
    $q->done->each(
        sub {
            is $_->return_status, 1, "Asset exists after worker got released from cache service" or die diag explain $_;
        });

    ok($cache_client->asset_exists('localhost', $asset), 'Asset downloaded') or die diag "Failed - no asset is there";
    is($sum, md5_sum(path($cachedir, 'localhost')->child($asset)->slurp), 'Download not corrupted');
};

subtest 'Default usage' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_1000@64bit.qcow2';
    my $asset_request = $cache_client->asset_request(id => 922756, asset => $asset, type => 'hdd', host => $host);

    unlink path($cachedir)->child($asset);
    ok(!$cache_client->asset_exists('localhost', $asset), 'Asset absent')
      or die diag "Asset already exists - abort test";

    my @logs;
    my $log_mock = Test::MockModule->new('Mojo::Log');
    $log_mock->redefine(info => sub { push @logs, $_[1] });
    BAIL_OUT("Failed enqueuing download") if $cache_client->enqueue($asset_request);
    perform_minion_jobs($t->app->minion);
    wait_for_or_bail_out { $cache_client->status($asset_request)->is_processed } 'asset';
    my $worker = $t->app->minion->repair->worker->register;
    my $status = $cache_client->status($asset_request);
    my $out = $cache_client->status($asset_request)->output;
    $worker->unregister;
    ok(scalar @logs, 'Output should be present') or die diag $out;
    like "@logs", qr/Downloading "$asset" from/, "Asset download attempt logged";
    ok(-e path($cachedir, 'localhost')->child($asset), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Small assets causes racing when releasing locks' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_1@64bit.qcow2';
    my $asset_request = $cache_client->asset_request(id => 922756, asset => $asset, type => 'hdd', host => $host);

    unlink path($cachedir)->child($asset);
    ok(!$cache_client->asset_exists('localhost', $asset), 'Asset absent')
      or die diag "Asset already exists - abort test";

    BAIL_OUT("Failed enqueuing download") if $cache_client->enqueue($asset_request);
    perform_minion_jobs($t->app->minion);
    wait_for_or_bail_out { $cache_client->status($asset_request)->is_processed } 'asset';
    my $out = $cache_client->status($asset_request)->output;
    ok($out, 'Output should be present') or die diag $out;
    like $out, qr/Downloading "$asset" from/, "Asset download attempt logged";
    ok($cache_client->asset_exists('localhost', $asset), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Asset download with default usage' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 3;
    test_default_usage(922756, "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2") for 1 .. $tot_proc;
};

subtest 'Multiple minion workers (parallel downloads, almost simulating real scenarios)' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 3;

    # We want 3 parallel downloads
    my $worker_2 = cache_minion_worker;
    my $worker_3 = cache_minion_worker;
    my $worker_4 = cache_minion_worker;

    $_->start for ($worker_2, $worker_3, $worker_4);

    my @assets = map { "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    my %requests
      = map { $_ => $cache_client->asset_request(id => 922756, asset => $_, type => 'hdd', host => $host) } @assets;
    ok(!$cache_client->enqueue($requests{$_}), "Download enqueued for $_") for @assets;

    wait_for_or_bail_out {
        (grep { $_ == 1 } map { $cache_client->status($requests{$_})->is_processed } @assets) == @assets
    }
    'assets';

    ok($cache_client->asset_exists('localhost', $_), "Asset $_ downloaded correctly") for @assets;

    @assets = map { "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    %requests
      = map { $_ => $cache_client->asset_request(id => 922756, asset => $_, type => 'hdd', host => $host) } @assets;
    ok(!$cache_client->enqueue($requests{$_}), "Download enqueued for $_") for @assets;

    wait_for_or_bail_out {
        (grep { $_ == 1 } map { $cache_client->status($requests{$_})->is_processed } @assets) == @assets
    }
    'assets';

    ok($cache_client->asset_exists('localhost', "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2"),
        "Asset $_ downloaded correctly")
      for @assets;

    $_->stop for ($worker_2, $worker_3, $worker_4);
};

subtest 'Test Minion task registration and execution' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';
    my $app = $t->app;
    my $req = $cache_client->asset_request(id => 922756, asset => $asset, type => 'hdd', host => $host);
    $cache_client->enqueue($req);
    my $worker = $app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    perform_job_in_foreground($job);
    my $status = $cache_client->status($req);
    ok $status->is_processed;
    ok $status->output;
    ok $cache_client->asset_exists('localhost', $asset);
};

subtest 'Test Minion Sync task' => sub {
    my $dir = tempdir;
    my $dir2 = tempdir;
    $dir->child('test')->spurt('foobar');
    my $expected = $dir2->child('tests')->child('test');

    my $req = $cache_client->rsync_request(from => $dir, to => $dir2);
    ok !$cache_client->enqueue($req);
    my $worker = $t->app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    perform_job_in_foreground($job);
    my $status = $cache_client->status($req);
    ok $status->is_processed;
    is $status->result, 'exit code 0';
    note $status->output;

    ok -e $expected;
    is $expected->slurp, 'foobar';
};

subtest 'Minion monitoring with InfluxDB' => sub {
    my $app = $t->app;
    my $rate = $app->cache->metrics->{download_rate};
    ok $rate > 0, 'download rate is higher than 0 bytes per second';

    my $url = $cache_client->url('/influxdb/minion');
    my $ua = $cache_client->ua;
    my $res = $ua->get($url)->result;
    is $res->body, <<"EOF", 'three workers still running';
openqa_minion_jobs,url=http://127.0.0.1:9530 active=0i,delayed=0i,failed=0i,inactive=0i
openqa_minion_workers,url=http://127.0.0.1:9530 active=0i,inactive=2i,registered=2i
openqa_download_rate,url=http://127.0.0.1:9530 bytes=${rate}i
EOF

    my $minion = $app->minion;
    my $worker = $minion->repair->worker->register;
    $res = $ua->get($url)->result;
    is $res->body, <<"EOF", 'four workers running now';
openqa_minion_jobs,url=http://127.0.0.1:9530 active=0i,delayed=0i,failed=0i,inactive=0i
openqa_minion_workers,url=http://127.0.0.1:9530 active=0i,inactive=3i,registered=3i
openqa_download_rate,url=http://127.0.0.1:9530 bytes=${rate}i
EOF

    $minion->add_task(test => sub { });
    my $job_id = $minion->enqueue('test');
    my $job_id2 = $minion->enqueue('test');
    my $job = $worker->dequeue(0);
    $res = $ua->get($url)->result;
    is $res->body, <<"EOF", 'two jobs';
openqa_minion_jobs,url=http://127.0.0.1:9530 active=1i,delayed=0i,failed=0i,inactive=1i
openqa_minion_workers,url=http://127.0.0.1:9530 active=1i,inactive=2i,registered=3i
openqa_download_rate,url=http://127.0.0.1:9530 bytes=${rate}i
EOF

    $job->fail('test');
    $res = $ua->get($url)->result;
    is $res->body, <<"EOF", 'one job failed';
openqa_minion_jobs,url=http://127.0.0.1:9530 active=0i,delayed=0i,failed=1i,inactive=1i
openqa_minion_workers,url=http://127.0.0.1:9530 active=0i,inactive=3i,registered=3i
openqa_download_rate,url=http://127.0.0.1:9530 bytes=${rate}i
EOF

    $job->retry({delay => ONE_HOUR});
    $res = $ua->get($url)->result;
    is $res->body, <<"EOF", 'job is being retried';
openqa_minion_jobs,url=http://127.0.0.1:9530 active=0i,delayed=1i,failed=0i,inactive=2i
openqa_minion_workers,url=http://127.0.0.1:9530 active=0i,inactive=3i,registered=3i
openqa_download_rate,url=http://127.0.0.1:9530 bytes=${rate}i
EOF
};

subtest 'Concurrent downloads of the same file' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';
    my $app = $t->app;
    my $req = $cache_client->asset_request(id => 922756, asset => $asset, type => 'hdd', host => $host);
    $cache_client->enqueue($req);
    my $req2 = $cache_client->asset_request(id => 922757, asset => $asset, type => 'hdd', host => $host);
    $cache_client->enqueue($req2);
    is $req->lock, $req2->lock, 'same lock';

    my $worker = $app->minion->repair->worker->register;
    ok $worker->id, 'worker has an ID';

    # Downloading job
    my $job = $worker->dequeue(0, {id => $req->minion_id});
    ok $job, 'job dequeued';
    ok !$app->progress->is_downloading($req->lock), 'not downloading yet';
    perform_job_in_foreground($job);
    my $status = $cache_client->status($req);
    ok $status->is_processed, 'is processed';
    my $info = $app->minion->job($req->minion_id)->info;
    ok !$info->{notes}{downloading_job}, 'no linked job';
    like $status->output, qr/Downloading "sle\-12\-SP3\-x86_64\-0368\-200_133333\@64bit.qcow2"/, 'right output';
    ok $cache_client->asset_exists('localhost', $asset), 'cached file exists';

    # Concurrent request for same file (logs are shared through status API)
    my $job2 = $worker->dequeue(0, {id => $req2->minion_id});
    ok $job2, 'job dequeued';
    ok !$app->progress->is_downloading($req2->lock), 'not downloading yet';
    ok my $guard = $app->progress->guard($req2->lock, $req->minion_id), 'lock acquired';
    ok $app->progress->is_downloading($req2->lock), 'concurrent download in progress';
    perform_job_in_foreground($job2);
    ok !$cache_client->status($req2)->is_processed, 'not yet processed';
    undef $guard;
    my $status2 = $cache_client->status($req2);
    ok $status2->is_processed, 'is processed';
    my $info2 = $app->minion->job($req2->minion_id)->info;
    ok $info2->{notes}{downloading_job}, 'downloading job is linked';
    like $info2->{notes}{output}, qr/Asset "sle.+" was downloaded by #\d+, details are therefore unavailable here/,
      'right output';
    like $status2->output, qr/Downloading "sle\-12\-SP3\-x86_64\-0368\-200_133333\@64bit.qcow2"/, 'right output';
    ok $cache_client->asset_exists('localhost', $asset), 'cached file still exists';

    # Downloading job has been removed (fallback for the rare case)
    $app->minion->job($req->minion_id)->remove;
    my $status3 = $cache_client->status($req2);
    ok $status3->is_processed, 'is processed';
    like $status3->output, qr/Asset "sle.+" was downloaded by #\d+, details are therefore unavailable here/,
      'right output';
};

subtest 'Concurrent rsync' => sub {
    my $dir = tempdir;
    my $dir2 = tempdir;
    $dir->child('test')->spurt('foobar');
    my $expected = $dir2->child('tests')->child('test');
    my $app = $t->app;
    my $req = $cache_client->rsync_request(from => $dir, to => $dir2);
    $cache_client->enqueue($req);
    my $req2 = $cache_client->rsync_request(from => $dir, to => $dir2);
    $cache_client->enqueue($req2);
    is $req->lock, $req2->lock, 'same lock';

    my $worker = $app->minion->repair->worker->register;
    ok $worker->id, 'worker has an ID';

    # Downloading job
    my $job = $worker->dequeue(0, {id => $req->minion_id});
    ok $job, 'job dequeued';
    ok !$app->progress->is_downloading($req->lock), 'not downloading yet';
    perform_job_in_foreground($job);
    my $status = $cache_client->status($req);
    ok $status->is_processed, 'is processed';
    is $status->result, 'exit code 0', 'expected result';
    my $info = $app->minion->job($req->minion_id)->info;
    ok !$info->{notes}{downloading_job}, 'no linked job';
    like $status->output, qr/sending incremental file list/, 'right output';
    ok -e $expected, 'target file exists';
    is $expected->slurp, 'foobar', 'expected content';

    # Concurrent request for same file (logs are shared through status API)
    my $job2 = $worker->dequeue(0, {id => $req2->minion_id});
    ok $job2, 'job dequeued';
    ok !$app->progress->is_downloading($req2->lock), 'not downloading yet';
    ok my $guard = $app->progress->guard($req2->lock, $req->minion_id), 'lock acquired';
    ok $app->progress->is_downloading($req2->lock), 'concurrent download in progress';
    perform_job_in_foreground($job2);
    ok !$cache_client->status($req2)->is_processed, 'not yet processed';
    undef $guard;
    my $status2 = $cache_client->status($req2);
    ok $status2->is_processed, 'is processed';
    is $status2->result, undef, 'expected result';
    my $info2 = $app->minion->job($req2->minion_id)->info;
    ok $info2->{notes}{downloading_job}, 'downloading job is linked';
    like $info2->{notes}{output}, qr/Sync ".+" to ".+" was performed by #\d+, details are therefore unavailable here/,
      'right output';
    like $status2->output, qr/sending incremental file list/, 'right output';
    ok -e $expected, 'target file exists';
    is $expected->slurp, 'foobar', 'expected content';

    # Downloading job has been removed (fallback for the rare case)
    $app->minion->job($req->minion_id)->remove;
    my $status3 = $cache_client->status($req2);
    ok $status3->is_processed, 'is processed';
    is $status3->result, undef, 'expected result';
    like $status3->output, qr/Sync ".+" to ".+" was performed by #\d+, details are therefore unavailable here/,
      'right output';
};

subtest 'OpenQA::CacheService::Task::Sync' => sub {
    my $worker_2 = cache_minion_worker;
    $worker_2->start;
    test_sync $_ for (1 .. 4);
    $worker_2->stop;
};

done_testing;

END {
    $server_instance->stop;
    $cache_service->stop;
}
