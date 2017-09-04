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
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
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
use Mojo::File qw(path);
use POSIX '_exit';

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

sub truncate_log {
    my ($new_log) = @_;
    my $logfile_ = ($new_log) ? $new_log : $logfile;
    open(my $f, '>', $logfile_) or die "OPENING $logfile_: $!\n";
    truncate $f, 0 or warn("Could not truncate");
}

sub read_log {
    my ($logfile) = @_;
    my $log_lines = path($logfile)->slurp;
    return $log_lines;
}

sub db_handle_connection {
    my $disconnect = @_;
    if ($dbh) {
        $dbh->disconnect;
        return if $disconnect;
    }

    $dbh
      = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1});

}

sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

my $daemon;
my $mock = Mojolicious->new;

sub start_server {
    $serverpid = fork();
    if ($serverpid == 0) {
        # setup mock

        $mock->routes->get(
            '/tests/:job/asset/:type/:filename' => sub {
                my $c        = shift;
                my $id       = $c->stash('job');
                my $type     = $c->stash('type');
                my $filename = $c->stash('filename');
                return $c->render(status => 404, text => "Move along, nothing to see here")
                  if $filename =~ /sle-12-SP3-x86_64-0368-404/;
                return $c->render(status => 400, text => "Move along, nothing to see here")
                  if $filename =~ /sle-12-SP3-x86_64-0368-400/;
                return $c->render(status => 500, text => "Move along, nothing to see here")
                  if $filename =~ /sle-12-SP3-x86_64-0368-500/;
                return $c->render(status => 503, text => "Move along, nothing to see here")
                  if $filename =~ /sle-12-SP3-x86_64-0368-503/;

                if ($filename =~ /sle-12-SP3-x86_64-0368-589/) {
                    $c->res->headers->content_length(10);
                    $c->inactivity_timeout(1);
                    $c->res->headers->content_type('text/plain');
                    $c->res->body('Six!!!');
                    $c->rendered(200);
                }

                if (my ($size) = ($filename =~ /sle-12-SP3-x86_64-0368-200_?([0-9]+)?\@/)) {
                    my $our_etag = 'andi $a3, $t1, 41399';

                    my $browser_etag = $c->req->headers->header('If-None-Match');
                    if ($browser_etag && $browser_etag eq $our_etag) {
                        $c->res->body('');
                        $c->rendered(304);
                    }
                    else {
                        $c->res->headers->content_length($size // 1024);
                        $c->inactivity_timeout(1);
                        $c->res->headers->content_type('text/plain');
                        $c->res->headers->header('ETag' => $our_etag);
                        $c->res->body("\0" x ($size // 1024));
                        $c->rendered(200);
                    }
                }
            });

        $mock->routes->get(
            '/' => sub {
                my $c = shift;
                return $c->render(status => 200, text => "server is running");
            });
        # Connect application with web server and start accepting connections
        $daemon = Mojo::Server::Daemon->new(app => $mock, listen => [$host]);
        $daemon->run;
        _exit(0);
    }
    sleep 1 while !_port($port);
    return;
}

sub stop_server {
    # now kill the worker
    kill TERM => $serverpid;
    sleep 1 while _port($port);
    is(waitpid($serverpid, 0), $serverpid, 'Server is done');
    $serverpid = undef;
}

OpenQA::Worker::Cache::init($host, $cachedir);
$openqalogs = read_log($logfile);
like $openqalogs, qr/Creating cache directory tree for/, "Cache directory tree created.";
like $openqalogs, qr/Deploying DB/,                      "Cache deploys the database.";
like $openqalogs, qr/Configured limit: 53687091200/,     "Cache limit is default (50GB).";
ok(-e $db_file, "cache.sqlite is present");

truncate_log $logfile;

db_handle_connection;

for (1 .. 3) {
    $filename = "$cachedir/$_.qcow2";
    open(my $tmpfd, '>:raw', $filename);
    print $tmpfd "\0" x 84 or die($filename);
    close $tmpfd;

    if ($_ % 2) {
        log_info "Inserting $_";
        $sql = "INSERT INTO assets (downloading,filename,size, etag,last_use)
                VALUES (0, ?, ?, 'Not valid', strftime('%s','now'));";
        $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $filename);
        $sth->bind_param(2, 84);
        $sth->execute();
    }

}

chdir $ENV{LOGDIR};

$OpenQA::Worker::Cache::sleep_time = 1;
OpenQA::Worker::Cache::init($host, $cachedir);

$openqalogs = read_log($logfile);
unlike $openqalogs, qr/Deploying DB/, "Cache deploys the database.";
like $openqalogs, qr/CACHE: Health: Real size: 168, Configured limit: 53687091200/,
  "Cache limit/size match the expected 100GB/168)";
unlike $openqalogs, qr/CACHE: Purging non registered.*[13].qcow2/, "Registered assets 1 and 3 were kept";
like $openqalogs,   qr/CACHE: Purging non registered.*2.qcow2/,    "Asset 2 was removed";
truncate_log $logfile;

$OpenQA::Worker::Cache::limit = 100;
OpenQA::Worker::Cache::init($host, $cachedir);

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Health: Real size: 84, Configured limit: 100/,
  "Cache limit/size match the expected 100/84)";
like $openqalogs, qr/CACHE: removed.*1.qcow2/, "Oldest asset (1.qcow2) removal was logged";
like $openqalogs, qr/$host/, "Host was initialized correctly ($host).";
ok(!-e "1.qcow2", "Oldest asset (1.qcow2) was sucessfully removed");
truncate_log $logfile;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');
my $autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 521/, "Asset download fails with: 521 - Connection refused";
truncate_log 'autoinst-log.txt';

$port = Mojo::IOLoop::Server->generate_port;
$host = "http://127.0.0.1:$port";
start_server;

$OpenQA::Worker::Cache::limit = 1024;
OpenQA::Worker::Cache::init($host, $cachedir);

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-404@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-404\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 404/, "Asset download fails with: 404 - Not Found";
truncate_log 'autoinst-log.txt';

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-400@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-400\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 400/, "Asset download fails with 400 - Bad Request";
truncate_log 'autoinst-log.txt';

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-589\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/Expected: 10 \/ Downloaded: 6/, "Incomplete download logged";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Error 598, retrying download for 4 more tries/, "4 tries remaining";
like $openqalogs, qr/CACHE: Waiting 1 seconds for the next retry/,          "1 second sleep_time set";
like $openqalogs, qr/CACHE: Too many download errors, aborting/,            "Bailing out after too many retries";
truncate_log $logfile;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-503@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-503\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/triggering a retry for 503/, "Asset download fails with 503 - Server not available";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/CACHE: Error 503, retrying download for 4 more tries/, "4 tries remaining";
like $openqalogs, qr/CACHE: Waiting 1 seconds for the next retry/,          "1 second sleep_time set";
like $openqalogs, qr/CACHE: Too many download errors, aborting/,            "Bailing out after too many retries";
truncate_log $logfile;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200.*, Cache size is: 1024/,
  "Full download logged";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/ andi \$a3, \$t1, 41399 and 1024/, "Etag and size are logged";
truncate_log $logfile;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/,      "Asset download attempt";
like $autoinst_log, qr/sle-12-SP3-x86_64-0368-200\@64bit.qcow2 but updating last use/, "last use gets updated";
truncate_log 'autoinst-log.txt';

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200_256@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-200_256\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200_256.*, Cache size is: 256/,
  "Full download logged";
truncate_log 'autoinst-log.txt';

$openqalogs = read_log($logfile);
like $openqalogs, qr/ andi \$a3, \$t1, 41399 and 256/, "Etag and size are logged";
like $openqalogs, qr/removed.*sle-12-SP3-x86_64-0368-200\@64bit.qcow2*/, "Reclaimed space for new smaller asset";
truncate_log $logfile;
stop_server;

done_testing();
