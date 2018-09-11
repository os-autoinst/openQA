#! /usr/bin/perl

# Copyright (c) 2017 SUSE LINUX GmbH, Nuernberg, Germany.
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
}

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;
use OpenQA::Utils;
use OpenQA::Worker::Cache;
use DBI;
use File::Path qw(remove_tree make_path);
use File::Spec::Functions qw(catdir catfile);
use Digest::MD5 qw(md5);
use Cwd qw(abs_path getcwd);

use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::File qw(path tempdir);
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use List::Util qw(shuffle uniq sum);
use Mojolicious::Commands;
use Mojo::UserAgent;
use OpenQA::Test::Utils qw(fake_asset_server);
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
my $logfile            = catdir($ENV{LOGDIR}, 'cache.log');
my $port               = Mojo::IOLoop::Server->generate_port;
my $host               = "http://localhost:$port";
my $cache_service_host = "http://localhost:3000";

make_path($ENV{LOGDIR});
use OpenQA::Worker::Cache::Client;

my $cache_client = OpenQA::Worker::Cache::Client->new(host => $cache_service_host);
BEGIN {
    my $cachedir = path('t', 'cache.d', 'cache');
    remove_tree($cachedir);
    $ENV{CACHE_DIR} = $cachedir;
}

END { session->clean }

# reassign STDOUT, STDERR
sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

my $daemon;
my $cache_service = process sub {
    use OpenQA::Worker::Cache::Service;
    diag 'Starting Cache service';
    Mojolicious::Commands->start_app('OpenQA::Worker::Cache::Service' => (qw(daemon), qw(-m production) x !(DEBUG)));
    _exit(0);
};

my $worker_cache_service = process sub {
    use OpenQA::Worker::Cache::Service;
    diag 'Starting Cache Worker';
    Mojolicious::Commands->start_app(
        'OpenQA::Worker::Cache::Service' => (qw(minion worker), qw(-m production) x !(DEBUG)));
    _exit(0);
};

my $server_instance = process sub {
    # Connect application with web server and start accepting connections
    $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host])->silent(!DEBUG);
    $daemon->run;
    _exit(0);
};

sub start_server {


    $server_instance->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $worker_cache_service->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $cache_service->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    sleep .5 until $cache_client->available;
    return;
}

sub test_download {
    my ($id, $a) = @_;

    my $resp = $cache_client->asset_download({id => $id, asset => $a, type => "hdd", host => $host});
    is($resp, OpenQA::Worker::Cache::Service::ASSET_STATUS_ENQUEUED) or die diag explain $resp;
    # Create double request
    $resp = $cache_client->asset_download({id => $id, asset => $a, type => "hdd", host => $host});
    is($resp, OpenQA::Worker::Cache::Service::ASSET_STATUS_IGNORE) or die diag explain $resp;

    sleep .5 until ($cache_client->asset_download_info($a) ne OpenQA::Worker::Cache::Service::ASSET_STATUS_IGNORE);

    #At some point, should start download
    $resp = $cache_client->asset_download_info($a);
    is($resp, OpenQA::Worker::Cache::Service::ASSET_STATUS_DOWNLOADING) or die diag explain $resp;

    sleep .5 until ($cache_client->asset_download_info($a) ne OpenQA::Worker::Cache::Service::ASSET_STATUS_DOWNLOADING);

    $resp = $cache_client->asset_download_info($a);
    is($resp, OpenQA::Worker::Cache::Service::ASSET_STATUS_PROCESSED) or die diag explain $resp;

    ok(-e path($cachedir)->child($a), 'Asset downloaded');
}

start_server;

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

subtest 'Asset download' => sub {
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_500@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_12200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_1200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2');
};

subtest 'Race for same asset' => sub {
    my $a   = 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2';
    my $sum = md5_sum(path($cachedir)->child($a)->slurp);
    unlink path($cachedir)->child($a);
    ok(!-e path($cachedir)->child($a), 'Asset absent') or die diag "Asset already exists - abort test";

    my $tot_proc   = $ENV{STRESS_TEST} ? 100 : 10;
    my $concurrent = $ENV{STRESS_TEST} ? 30  : 2;
    my $q          = queue;
    $q->pool->maximum_processes($concurrent);
    $q->queue->maximum_processes($tot_proc);
    my @test = uniq(map { int(rand(2000)) + 150 } 1 .. ($tot_proc / 2));
    #my $sum = sum(@test) + 2000;
    #diag "Testing downloading " . (scalar @test) . " assets of ($sum) @test size";

    my $concurrent_test = sub {
        $cache_client->asset_download("download", {id => 922756, asset => $a, type => "hdd", host => $host});
        sleep .5 until ($cache_client->asset_download_info($a) ne OpenQA::Worker::Cache::Service::ASSET_STATUS_IGNORE);
    };

    $q->add(process($concurrent_test)->set_pipes(0)->internal_pipes(0)) for 1 .. $tot_proc;

    $q->consume();
    is $q->done->size, $tot_proc, 'Queue consumed ' . $tot_proc . ' processes';

    ok(-e path($cachedir)->child($a), 'Asset downloaded') or die diag "Failed - no asset is there``";
    is($sum, md5_sum(path($cachedir)->child($a)->slurp), 'Download not corrupted');
};


done_testing();
