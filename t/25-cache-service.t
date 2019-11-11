#! /usr/bin/perl

# Copyright (c) 2018-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

my $tempdir;
BEGIN {
    unshift @INC, 't/lib';
    use Mojo::File qw(path tempdir);
    use FindBin;

    $tempdir = tempdir;
    my $basedir = $tempdir->child('t', 'cache.d');
    $ENV{OPENQA_CACHE_DIR} = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR}   = $basedir;
    $ENV{OPENQA_CONFIG}    = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt('
[global]
CACHEDIRECTORY = ' . $ENV{OPENQA_CACHE_DIR} . '
CACHEWORKERS = 10
CACHELIMIT = 100');
}

# Avoid warning error: Name "Config::IniFiles::t/cache.d/cache/config/workers.ini" used only once
use OpenQA::CacheService::Model::Cache;
OpenQA::CacheService::Model::Cache->from_worker;

use Test::More;
use Test::Warnings;
use OpenQA::Utils;
use File::Spec::Functions qw(catdir catfile);
use Cwd qw(abs_path getcwd);
use Minion;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server cache_minion_worker cache_worker_service);
use OpenQA::Test::FakeWebSocketTransaction;
use Mojo::Util qw(md5_sum);
use OpenQA::CacheService;
use OpenQA::CacheService::Request;
use OpenQA::CacheService::Client;
use OpenQA::CacheService::Task::Asset;
use OpenQA::CacheService::Task::Sync;
use Test::MockModule;

my $sql;
my $sth;
my $result;
my $dbh;
my $filename;
my $serverpid;
my $openqalogs;
my $cachedir = $ENV{OPENQA_CACHE_DIR};

my $db_file = "$cachedir/cache.sqlite";
my $logdir  = path(getcwd(), 't', 'cache.d', 'logs')->make_path;
my $logfile = $logdir->child('cache.log');
my $port    = Mojo::IOLoop::Server->generate_port;
my $host    = "http://localhost:$port";

my $cache_client = OpenQA::CacheService::Client->new();

sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

END { session->clean }

my $daemon;
my $cache_service        = cache_worker_service;
my $worker_cache_service = cache_minion_worker;

my $server_instance = process sub {
    # Connect application with web server and start accepting connections
    $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host])->silent(1);
    $daemon->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $cache_service->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart->restart;
    $worker_cache_service->restart;
    sleep 2 and diag "Wait server to be reachable." until $cache_client->info->available;
    return;
}

sub test_default_usage {
    my ($id, $a) = @_;
    my $asset_request = $cache_client->asset_request(id => $id, asset => $a, type => 'hdd', host => $host);

    if ($cache_client->enqueue($asset_request)) {
        sleep .5 until $cache_client->status($asset_request)->is_processed;
    }
    ok($cache_client->asset_exists('localhost', $a), "Asset $a downloaded");
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

sub test_sync {
    my $dir           = tempdir;
    my $dir2          = tempdir;
    my $rsync_request = $cache_client->rsync_request(from => $dir, to => $dir2);

    my $t_dir = int(rand(13432432));
    my $data  = int(rand(348394280934820842093));
    $dir->child($t_dir)->spurt($data);
    my $expected = $dir2->child('tests')->child($t_dir);

    ok $cache_client->enqueue($rsync_request);

    sleep .5 until $cache_client->status($rsync_request)->is_processed;

    my $status = $cache_client->status($rsync_request);
    is $status->result, 0;
    ok $status->output;

    like $status->output, qr/100\%/ or die diag $status->output;

    ok -e $expected;
    is $expected->slurp, $data;
}

sub test_download {
    my ($id, $a) = @_;
    unlink path($cachedir)->child($a);
    my $asset_request = $cache_client->asset_request(id => $id, asset => $a, type => 'hdd', host => $host);

    ok $cache_client->enqueue($asset_request), 'enqueued';

    my $status = $cache_client->status($asset_request);
    $status = $cache_client->status($asset_request) until !$status->is_downloading;

    # And then goes to PROCESSED state
    ok $status->is_processed, 'only other state is processed';

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded');
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

# Allow Devel::Cover to collect stats for background jobs
sub fix_coverage {
    my $app = shift;
    $app->minion->on(
        worker => sub {
            my ($minion, $worker) = @_;
            $worker->on(
                dequeue => sub {
                    my ($worker, $job) = @_;
                    $job->on(cleanup => sub { Devel::Cover::report() if Devel::Cover->can('report') });
                });
        });
}

subtest 'OPENQA_CACHE_DIR environment variable' => sub {
    local $ENV{OPENQA_CACHE_DIR} = '/does/not/exist';
    my $client = OpenQA::CacheService::Client->new;
    is $client->cache_dir, '/does/not/exist', 'environment variable used';
};

subtest 'Availability check and worker status' => sub {
    my $client_mock = Test::MockModule->new('OpenQA::CacheService::Response::Info');

    my $info = $cache_client->info;
    is($info->availability_error, 'Cache service not reachable', 'cache service not available');

    $client_mock->mock(available         => sub { return 1; });
    $client_mock->mock(available_workers => sub { return 0; });
    is($info->availability_error, 'No workers active in the cache service', 'nor workers active');

    $client_mock->mock(available_workers => sub { return 1; });
    is($info->availability_error, undef, 'no error');

    $client_mock->unmock_all();
};

subtest 'Configurable minion workers' => sub {
    is_deeply([OpenQA::CacheService::setup_workers(qw(minion test))],   [qw(minion test)]);
    is_deeply([OpenQA::CacheService::setup_workers(qw(minion worker))], [qw(minion worker -j 10)]);
    is_deeply([OpenQA::CacheService::setup_workers(qw(minion daemon))], [qw(minion daemon)]);

    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("
[global]
CACHEDIRECTORY = $cachedir
CACHELIMIT = 100");

    is_deeply([OpenQA::CacheService::setup_workers(qw(minion worker))], [qw(minion worker -j 5)]);
};

subtest 'Cache Requests' => sub {
    my $asset_request = $cache_client->asset_request(id => 922756, asset => 'test', type => 'hdd', host => 'open.qa');
    my $rsync_request = $cache_client->rsync_request(from => 'foo', to => 'bar');

    is $rsync_request->lock, join('.', 'foo',  'bar');
    is $asset_request->lock, join('.', 'test', 'open.qa');

    is_deeply $rsync_request->to_array, [qw(foo bar)];
    is_deeply $asset_request->to_array, [qw(922756 hdd test open.qa)];

    my $base = OpenQA::CacheService::Request->new;
    local $@;
    eval { $base->lock };
    like $@, qr/lock\(\) not implemented in OpenQA::CacheService::Request/, 'lock() not implemented in base request';
    eval { $base->to_array };
    like $@, qr/to_array\(\) not implemented in OpenQA::CacheService::Request/,
      'to_array() not implemented in base request';
};

start_server;

subtest 'Invalid requests' => sub {
    my $url             = $cache_client->url('/status/12345');
    my $invalid_request = $cache_client->ua->get($url);
    my $json            = $invalid_request->result->json;
    is_deeply($json, {error => 'Specified job ID is invalid'}, 'invalid job ID') or diag explain $json;

    $url             = $cache_client->url('/status/abc');
    $invalid_request = $cache_client->ua->get($url);
    is $invalid_request->res->code, 404, 'invalid job ID';

    $url             = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {args => []});
    $json            = $invalid_request->result->json;
    is_deeply($json, {error => 'No task defined'}, 'invalid task') or diag explain $json;

    $url             = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {task => 'cache_asset'});
    $json            = $invalid_request->result->json;
    is_deeply($json, {error => 'No arguments defined'}, 'invalid args') or diag explain $json;

    $url             = $cache_client->url('/enqueue');
    $invalid_request = $cache_client->ua->post($url => json => {task => 'cache_asset', args => []});
    $json            = $invalid_request->result->json;
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

subtest 'Job progress (guard against parallel downloads of the same file)' => sub {
    my $app = OpenQA::CacheService->new;
    ok !$app->progress->is_downloading('foo'), 'Queue works';
    my $guard = $app->progress->guard('foo');
    ok $app->progress->is_downloading('foo'), 'Queue works';
    ok $app->progress->is_downloading('foo'), 'Queue works';
    undef $guard;
    ok !$app->progress->is_downloading('foo'), 'Dequeue works';
};

subtest 'Client can check if there are available workers' => sub {
    $worker_cache_service->stop;
    $cache_service->stop;
    ok !$cache_client->info->available, 'Cache server is not available';
    $cache_service->restart;
    sleep .5 until $cache_client->info->available;
    ok $cache_client->info->available, 'Cache server is available';
    ok !$cache_client->info->available_workers, 'No available workers at the moment';
    $worker_cache_service->start;
    sleep 5 and diag "waiting for minion worker to be available" until $cache_client->info->available_workers;
    ok $cache_client->info->available_workers, 'Workers are available now';
};

subtest 'Asset download' => sub {
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_2900@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_2700@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_5500@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_12200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_15200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2');
};

subtest 'Race for same asset' => sub {

    my $a = 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2';

    my $asset_request = $cache_client->asset_request(id => 922756, asset => $a, type => 'hdd', host => $host);

    my $sum = md5_sum(path($cachedir, 'localhost')->child($a)->slurp);
    unlink path($cachedir, 'localhost')->child($a)->to_string;
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    my $tot_proc   = $ENV{STRESS_TEST} ? 100 : 10;
    my $concurrent = $ENV{STRESS_TEST} ? 30  : 2;
    my $q          = queue;
    $q->pool->maximum_processes($concurrent);
    $q->queue->maximum_processes($tot_proc);

    my $concurrent_test = sub {
        if ($cache_client->enqueue($asset_request)) {
            sleep .5 until $cache_client->status($asset_request)->is_processed;
            Devel::Cover::report() if Devel::Cover->can('report');

            return 1 if $cache_client->asset_exists('localhost', $a);
            return 0;
        }
    };

    $q->add(process($concurrent_test)->set_pipes(0)->internal_pipes(1)) for 1 .. $tot_proc;

    $q->consume();
    is $q->done->size, $tot_proc, 'Queue consumed ' . $tot_proc . ' processes';
    $q->done->each(
        sub {
            is $_->return_status, 1, "Asset exists after worker got released from cache service" or die diag explain $_;
        });

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
    is($sum, md5_sum(path($cachedir, 'localhost')->child($a)->slurp), 'Download not corrupted');
};

subtest 'Default usage' => sub {
    my $a             = 'sle-12-SP3-x86_64-0368-200_1000@64bit.qcow2';
    my $asset_request = $cache_client->asset_request(id => 922756, asset => $a, type => 'hdd', host => $host);

    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($cache_client->enqueue($asset_request)) {
        sleep .5 until $cache_client->status($asset_request)->is_processed;
        my $out = $cache_client->status($asset_request)->output;
        ok($out, 'Output should be present') or die diag $out;
        like $out, qr/Downloading $a from/, "Asset download attempt logged";
        ok(-e path($cachedir, 'localhost')->child($a), 'Asset downloaded') or die diag "Failed - no asset is there";
    }
    else {
        fail("Failed enqueuing download");
    }

    ok(-e path($cachedir, 'localhost')->child($a), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Small assets causes racing when releasing locks' => sub {
    my $a             = 'sle-12-SP3-x86_64-0368-200_1@64bit.qcow2';
    my $asset_request = $cache_client->asset_request(id => 922756, asset => $a, type => 'hdd', host => $host);

    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($cache_client->enqueue($asset_request)) {
        1 until $cache_client->status($asset_request)->is_processed;
        my $out = $cache_client->status($asset_request)->output;
        ok($out, 'Output should be present') or die diag $out;
        like $out, qr/Downloading $a from/, "Asset download attempt logged";
        ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
    }
    else {
        fail("Failed enqueuing download");
    }

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Asset download with default usage' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 10;
    test_default_usage(922756, "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2") for 1 .. $tot_proc;
};

subtest 'Multiple minion workers (parallel downloads, almost simulating real scenarios)' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 10;

    # We want 3 parallel downloads
    my $worker_2 = cache_minion_worker;
    my $worker_3 = cache_minion_worker;
    my $worker_4 = cache_minion_worker;

    $_->start for ($worker_2, $worker_3, $worker_4);

    my @assets = map { "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    my %requests
      = map { $_ => $cache_client->asset_request(id => 922756, asset => $_, type => 'hdd', host => $host) } @assets;
    ok($cache_client->enqueue($requests{$_}), "Download enqueued for $_") for @assets;

    sleep 1 until (grep { $_ == 1 } map { $cache_client->status($requests{$_})->is_processed } @assets) == @assets;

    ok($cache_client->asset_exists('localhost', $_), "Asset $_ downloaded correctly") for @assets;

    @assets = map { "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    %requests
      = map { $_ => $cache_client->asset_request(id => 922756, asset => $_, type => 'hdd', host => $host) } @assets;
    ok($cache_client->enqueue($requests{$_}), "Download enqueued for $_") for @assets;

    sleep 1 until (grep { $_ == 1 } map { $cache_client->status($requests{$_})->is_processed } @assets) == @assets;

    ok($cache_client->asset_exists('localhost', "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2"),
        "Asset $_ downloaded correctly")
      for @assets;

    $_->stop for ($worker_2, $worker_3, $worker_4);
};

subtest 'Test Minion task registration and execution' => sub {
    my $a = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';

    my $app = OpenQA::CacheService->new;
    fix_coverage($app);

    my $req = $cache_client->asset_request(id => 922756, asset => $a, type => 'hdd', host => $host);
    $cache_client->enqueue($req);
    my $worker = $app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    $job->perform;
    my $status = $cache_client->status($req);
    ok $status->is_processed;
    ok $status->output;
    ok $cache_client->asset_exists('localhost', $a);
};

subtest 'Test Minion Sync task' => sub {
    my $a = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';

    my $app = OpenQA::CacheService->new;
    fix_coverage($app);

    my $dir  = tempdir;
    my $dir2 = tempdir;
    $dir->child('test')->spurt('foobar');
    my $expected = $dir2->child('tests')->child('test');

    my $req = $cache_client->rsync_request(from => $dir, to => $dir2);
    ok $cache_client->enqueue($req);
    my $worker = $app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    $job->perform;
    my $status = $cache_client->status($req);
    ok $status->is_processed;
    is $status->result, 0;
    diag $status->output;

    ok -e $expected;
    is $expected->slurp, 'foobar';
};

subtest 'OpenQA::CacheService::Task::Sync' => sub {
    my $worker_2 = cache_minion_worker;
    $worker_cache_service->stop;

    $worker_2->start;

    test_sync;
    test_sync;
    test_sync;
    test_sync;

    $worker_2->stop;
};

done_testing();

1;
