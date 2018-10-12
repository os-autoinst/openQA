#! /usr/bin/perl

# Copyright (c) 2018 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib', 't/lib';
    use Mojo::File qw(path tempdir);
    use FindBin;
    use File::Path qw(remove_tree make_path);

    my $basedir = path(tempdir, 't', 'cache.d');
    remove_tree($basedir);
    $ENV{CACHE_DIR}      = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR} = $basedir;
    $ENV{OPENQA_CONFIG}  = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("
[global]
CACHEDIRECTORY = $cachedir
CACHELIMIT = 100");
}

use strict;
use warnings;
# Avoid warning error: Name "Config::IniFiles::t/cache.d/cache/config/workers.ini" used only once
use OpenQA::Worker::Cache;
OpenQA::Worker::Cache->from_worker;
use Test::More;
use Test::Warnings;
use OpenQA::Utils;
use File::Spec::Functions qw(catdir catfile);
use Cwd qw(abs_path getcwd);
use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server cache_minion_worker cache_worker_service);
use Mojo::Util qw(md5_sum);
use constant DEBUG => $ENV{DEBUG} // 0;

my $sql;
my $sth;
my $result;
my $dbh;
my $filename;
my $serverpid;
my $openqalogs;
my $cachedir = $ENV{CACHE_DIR};

my $db_file = "$cachedir/cache.sqlite";
$ENV{LOGDIR} = catdir(getcwd(), 't', 'cache.d', 'logs');
my $logfile = catdir($ENV{LOGDIR}, 'cache.log');
my $port    = Mojo::IOLoop::Server->generate_port;
my $host    = "http://localhost:$port";

make_path($ENV{LOGDIR});
use OpenQA::Worker::Cache::Client;

my $cache_client = OpenQA::Worker::Cache::Client->new();

# reassign STDOUT, STDERR
sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }
sub _cover {
    session->all->each(sub { $_->signal(POSIX::SIGUSR1) });
}

END { _cover; session->clean }

my $daemon;
my $cache_service        = cache_worker_service;
my $worker_cache_service = cache_minion_worker;

my $server_instance = process sub {
    # Connect application with web server and start accepting connections
    $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host])->silent(!DEBUG);
    $daemon->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $cache_service->restart;
    $worker_cache_service->restart;
    sleep 2 and diag "Wait server to be available" until $cache_client->available;
    return;
}

sub test_default_usage {
    my ($id, $a) = @_;
    if ($cache_client->enqueue_download({id => $id, asset => $a, type => "hdd", host => $host})) {
        1 until $cache_client->processed($a);
    }
    ok($cache_client->asset_exists('localhost', $a), "Asset $a downloaded");
}

sub test_download {
    my ($id, $a) = @_;
    unlink path($cachedir)->child($a);

    my $resp = $cache_client->asset_download({id => $id, asset => $a, type => "hdd", host => $host});
    is($resp, OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED) or die diag explain $resp;

    my $state = $cache_client->asset_download_info($a);
    $state = $cache_client->asset_download_info($a) until ($state ne OpenQA::Worker::Cache::ASSET_STATUS_IGNORE);

    # After IGNORE, only DOWNLOAD status could follow, but it could be fast enough to not catch it
    $state = $cache_client->asset_download_info($a);
    $state = $cache_client->asset_download_info($a) until ($state ne OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING);

    # And then goes to PROCESSED state
    is($state, OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED) or die diag explain $resp;

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded');
}

start_server;

subtest 'Asset exists' => sub {

    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent');
    path($cachedir, 'localhost')->make_path->child('foobar')->spurt('test');

    ok($cache_client->asset_exists('localhost', 'foobar'), 'Asset exists');
    unlink path($cachedir, 'localhost')->child('foobar')->to_string;
    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent')
      or die diag explain path($cachedir, 'localhost')->list_tree;

};

subtest 'different token between restarts' => sub {
    my $token = $cache_client->session_token;
    ok(defined $token);
    ok($token ne "");
    diag "Session token: $token";

    start_server;
    isnt($cache_client->session_token, $token) or die diag $cache_client->session_token;

    $token = $cache_client->session_token;
    ok(defined $token);
    ok($token ne "");
};

subtest 'enqueued' => sub {
    require OpenQA::Worker::Cache::Service;

    OpenQA::Worker::Cache::Service::enqueue('bar');
    ok !OpenQA::Worker::Cache::Service::enqueued('foo'), "Queue works" or die;
    OpenQA::Worker::Cache::Service::enqueue('foo');
    ok OpenQA::Worker::Cache::Service::enqueued('foo'), "Queue works";
    OpenQA::Worker::Cache::Service::dequeue('foo');
    ok !OpenQA::Worker::Cache::Service::enqueued('foo'), "Dequeue works";
};

subtest '_gen_guard_name' => sub {
    require OpenQA::Worker::Cache::Service;

    ok !OpenQA::Worker::Cache::Service::SESSION_TOKEN(), "Session token is not there" or die;
    OpenQA::Worker::Cache::Service::_gen_session_token();
    ok OpenQA::Worker::Cache::Service::SESSION_TOKEN(), "Session token is there" or die;
    is OpenQA::Worker::Cache::Service::_gen_guard_name('foo'),
      OpenQA::Worker::Cache::Service::SESSION_TOKEN() . '.foo', "Session token is there"
      or die;
};

subtest '_exists' => sub {
    require OpenQA::Worker::Cache::Service;

    ok !OpenQA::Worker::Cache::Service::_exists();
    ok !OpenQA::Worker::Cache::Service::_exists({total => 0});
    ok OpenQA::Worker::Cache::Service::_exists({total => 1});
    ok OpenQA::Worker::Cache::Service::_exists({total => 100});
};

subtest 'Client can check if there are available workers' => sub {
    $cache_client->session_token;
    $worker_cache_service->stop;
    $cache_service->restart;
    sleep .5 until $cache_client->available;
    ok $cache_client->available;
    $worker_cache_service->start;
    sleep 5 and diag "waiting for minion worker to be available" until $cache_client->available_workers;
    ok $cache_client->available_workers;
    #  _cover;
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
    my $sum = md5_sum(path($cachedir, 'localhost')->child($a)->slurp);
    unlink path($cachedir, 'localhost')->child($a)->to_string;
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    my $tot_proc   = $ENV{STRESS_TEST} ? 100 : 10;
    my $concurrent = $ENV{STRESS_TEST} ? 30  : 2;
    my $q          = queue;
    $q->pool->maximum_processes($concurrent);
    $q->queue->maximum_processes($tot_proc);

    my $concurrent_test = sub {
        if ($cache_client->enqueue_download({id => 922756, asset => $a, type => "hdd", host => $host})) {
            1 until $cache_client->processed($a);
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
    my $a = 'sle-12-SP3-x86_64-0368-200_1000@64bit.qcow2';
    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($cache_client->enqueue_download({id => 922756, asset => $a, type => "hdd", host => $host})) {
        1 until $cache_client->processed($a);
        my $out = $cache_client->asset_download_output($a);
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
    my $a = 'sle-12-SP3-x86_64-0368-200_1@64bit.qcow2';
    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($cache_client->enqueue_download({id => 922756, asset => $a, type => "hdd", host => $host})) {
        1 until $cache_client->processed($a);
        my $out = $cache_client->asset_download_output($a);
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
    ok($cache_client->enqueue_download({id => 922756, asset => $_, type => "hdd", host => $host}),
        "Download enqueued for $_")
      for @assets;

    sleep 1 until (grep { $_ == 1 } map { $cache_client->processed($_) } @assets) == @assets;

    ok($cache_client->asset_exists('localhost', $_), "Asset $_ downloaded correctly") for @assets;

    @assets = map { "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    ok($cache_client->enqueue_download({id => 922756, asset => $_, type => "hdd", host => $host}),
        "Download enqueued for $_")
      for @assets;

    sleep 1 until (grep { $_ == 1 } map { $cache_client->processed($_) } @assets) == @assets;

    ok($cache_client->asset_exists('localhost', "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2"),
        "Asset $_ downloaded correctly")
      for @assets;

};

done_testing();
