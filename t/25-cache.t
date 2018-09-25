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
use Mojo::SQLite;
use Mojo::File qw(path);
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use List::Util qw(shuffle uniq sum);
use OpenQA::Test::Utils qw(fake_asset_server);

my $sql;
my $sth;
my $result;
my $dbh;
my $filename;
my $serverpid;
my $openqalogs;

my $cachedir = catdir(getcwd(), 't', 'cache.d', 'cache');
my $db_file = "$cachedir/cache.sqlite";
$ENV{LOGDIR} = catdir(getcwd(), 't', 'cache.d', 'logs');
my $logfile = catdir($ENV{LOGDIR}, 'cache.log');
my $port    = Mojo::IOLoop::Server->generate_port;
my $host    = "http://localhost:$port";

remove_tree($cachedir);
make_path($ENV{LOGDIR});

# reassign STDOUT, STDERR
open my $FD, '>>', $logfile;
*STDOUT = $FD;
*STDERR = $FD;

$SIG{INT} = sub {
    session->clean;
};

END { session->clean }

sub truncate_log {
    my ($new_log) = @_;
    my $logfile_ = ($new_log) ? $new_log : $logfile;
    open(my $f, '>', $logfile_) or die "OPENING $logfile_: $!\n";
    truncate $f, 0 or warn("Could not truncate");
    close $f;
}

sub read_log {
    my ($logfile) = @_;
    my $log_lines = path($logfile)->slurp;
    return $log_lines;
}

sub db_handle_connection {
    my ($cache, $disconnect) = @_;
    if ($cache->dbh) {
        $cache->dbh->db->disconnect;
        return if $disconnect;
    }

    $cache->dbh(Mojo::SQLite->new("sqlite:$db_file"));
}

sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

my $daemon;
my $mock            = Mojolicious->new;
my $server_instance = process sub {
    $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host]);
    $daemon->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->start;
    sleep 1 while !_port($port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

my $cache = OpenQA::Worker::Cache->new(host => $host, location => $cachedir);
is $cache->init, $cache;
$openqalogs = read_log($logfile);
like $openqalogs, qr/Creating cache directory tree for/, "Cache directory tree created.";
like $openqalogs, qr/Deploying DB/,                      "Cache deploys the database.";
like $openqalogs, qr/Configured limit: 53687091200/,     "Cache limit is default (50GB).";
ok(-e $db_file, "cache.sqlite is present");
truncate_log $logfile;

db_handle_connection($cache);

for (1 .. 3) {
    $filename = "$cachedir/$_.qcow2";
    open(my $tmpfd, '>:raw', $filename);
    print $tmpfd "\0" x 84 or die($filename);
    close $tmpfd;

    if ($_ % 2) {
        log_info "Inserting $_";
        $sql = "INSERT INTO assets (filename,size, etag,last_use)
                VALUES ( ?, ?, 'Not valid', strftime('\%s','now'));";
        $cache->dbh->db->query($sql, $filename, 84);
    }
}


chdir $ENV{LOGDIR};

$cache->sleep_time(1);
$cache->init;

$openqalogs = read_log($logfile);
unlike $openqalogs, qr/Deploying DB/, "Cache deploys the database.";
like $openqalogs, qr/CACHE: Health: Real size: 168, Configured limit: 53687091200/,
  "Cache limit/size match the expected 100GB/168)";
unlike $openqalogs, qr/CACHE: Purging non registered.*[13].qcow2/, "Registered assets 1 and 3 were kept";
like $openqalogs,   qr/CACHE: Purging non registered.*2.qcow2/,    "Asset 2 was removed";
truncate_log $logfile;

$cache->limit(100);
$cache->init;

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Health: Real size: 84, Configured limit: 100/,
  "Cache limit/size match the expected 100/84)";
like $openqalogs, qr/CACHE: removed.*1.qcow2/, "Oldest asset (1.qcow2) removal was logged";
like $openqalogs, qr/$host/, "Host was initialized correctly ($host).";
ok(!-e "1.qcow2", "Oldest asset (1.qcow2) was sucessfully removed");
truncate_log $logfile;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');
my $autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 521/, "Asset download fails with: 521 - Connection refused";
truncate_log 'autoinst-log.txt';

$port = Mojo::IOLoop::Server->generate_port;
$host = "http://127.0.0.1:$port";
start_server;

$cache->host($host);
$cache->limit(1024);
$cache->init;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-404@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-404\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 404/, "Asset download fails with: 404 - Not Found";
truncate_log 'autoinst-log.txt';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-400@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-400\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 400/, "Asset download fails with 400 - Bad Request";
truncate_log 'autoinst-log.txt';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-589\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/Expected: 10 \/ Downloaded: 6/, "Incomplete download logged";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Error 598, retrying download for 4 more tries/, "4 tries remaining";
like $openqalogs, qr/CACHE: Waiting 1 seconds for the next retry/,          "1 second sleep_time set";
like $openqalogs, qr/CACHE: Too many download errors, aborting/,            "Bailing out after too many retries";
truncate_log $logfile;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-503@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-503\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/triggering a retry for 503/, "Asset download fails with 503 - Server not available";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Error 503, retrying download for 4 more tries/, "4 tries remaining";
like $openqalogs, qr/CACHE: Waiting 1 seconds for the next retry/,          "1 second sleep_time set";
like $openqalogs, qr/CACHE: Too many download errors, aborting/,            "Bailing out after too many retries";
truncate_log $logfile;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200.*, Cache size is: 1024/,
  "Full download logged";
truncate_log 'autoinst-log.txt';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/CACHE: Content has not changed, not downloading .* but updating last use/, "Upading last use";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/ andi \$a3, \$t1, 41399 and 1024/, "Etag and size are logged";
truncate_log $logfile;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/,      "Asset download attempt";
like $autoinst_log, qr/sle-12-SP3-x86_64-0368-200\@64bit.qcow2 but updating last use/, "last use gets updated";
truncate_log 'autoinst-log.txt';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200_256@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200_256\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200_256.*, Cache size is: 256/,
  "Full download logged";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/ andi \$a3, \$t1, 41399 and 256/, "Etag and size are logged";
like $openqalogs, qr/removed.*sle-12-SP3-x86_64-0368-200\@64bit.qcow2*/, "Reclaimed space for new smaller asset";
truncate_log $logfile;

$cache->track_asset("Foobar", 0);

$cache->dbh->db->query("delete from assets");

my $fake_asset = "$cachedir/test.qcow";

path($fake_asset)->spurt('');
ok -e $fake_asset, 'Asset is there';
$cache->asset_lookup($fake_asset);
ok !-e $fake_asset, 'Asset was purged since was not tracked';

path($fake_asset)->spurt('');
ok -e $fake_asset, 'Asset is there';
$cache->purge_asset($fake_asset);
ok !-e $fake_asset, 'Asset was purged';

$cache->track_asset($fake_asset);
is $cache->_asset($fake_asset)->{etag}, 0, 'Can get downloading state with _asset()';
is_deeply $cache->_asset('foobar'), {}, '_asset() returns {} if asset is not present';

path($fake_asset)->spurt('');
is $cache->check_limits(2333), 0, 'Freed no space - locked assets are not removed';
is $cache->check_limits(2333), 1, '1 Asset purged to make space';

stop_server;
done_testing();
