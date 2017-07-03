#! /usr/bin/perl

# Copyright (c) 2016 SUSE LINUX GmbH, Nuernberg, Germany.
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

my $sql;
my $sth;
my $result;
my $dbh;
my $filename;
my $serverpid;

my $cachedir = catdir(getcwd(), 't/cache.d/cache');
my $db_file = "$cachedir/cache.sqlite";
$ENV{LOGDIR} = catdir(getcwd(), 't/cache.d', 'logs');
my $logfile = catdir($ENV{LOGDIR}, 'cache.log');
my $port    = Mojo::IOLoop::Server->generate_port;
my $host    = "http://localhost:$port";

remove_tree($cachedir);
make_path($ENV{LOGDIR});

#redirect stdout
open(my $FD, '>>', $logfile);
select $FD;
$| = 1;

sub truncate_log {
    truncate $FD, 0;
}


sub read_log {
    my ($new_log) = @_;
    my $logfile_ = ($new_log) ? $new_log : $logfile;
    open(my $f, '<', $logfile_) or die "OPENING $logfile_: $!\n";
    my $log = do { local ($/); <$f> };
    close($f);
    truncate $f, 0;
    return $log;
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
OpenQA::Worker::Cache::init($host, $cachedir);

like read_log, qr/Creating cache directory tree for/, "Cache directory tree created.";
like read_log, qr/Deploying DB/,                      "Cache deploys the database.";
like read_log, qr/Configured limit: 53687091200/,     "Cache limit is default (50GB).";
ok(-e $db_file, "cache.sqlite is present");


truncate_log;

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

OpenQA::Worker::Cache::init($host, $cachedir);

unlike read_log, qr/Deploying DB/, "Cache deploys the database.";
like read_log, qr/CACHE: Health: Real size: 168, Configured limit: 53687091200/,
  "Cache limit/size match the expected 100GB/168)";
unlike read_log, qr/CACHE: Purging non registered.*[13].qcow2/, "Registered assets 1 and 3 were kept";
like read_log,   qr/CACHE: Purging non registered.*2.qcow2/,    "Asset 2 was removed";
truncate_log;

$OpenQA::Worker::Cache::limit = 100;
OpenQA::Worker::Cache::init($host, $cachedir);

like read_log, qr/CACHE: Health: Real size: 84, Configured limit: 100/, "Cache limit/size match the expected 100/84)";
like read_log, qr/CACHE: removed.*1.qcow2/, "Oldest asset (1.qcow2) removal was logged";
ok(!-e "$cachedir/1.qcow2", "Oldest asset (1.qcow2) was sucessfully removed");
truncate_log;
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
                  if $filename =~ /sle-12-SP3-x86_64-0368-589/;
                if ($filename =~ /sle-12-SP3-x86_64-0368-589/) {
                    $c->res->headers->content_length(10);
                    $c->write(
                        'Hel' => sub {
                            my $c = shift;
                            $c->write('lo!');
                        });
                }
            });

        $mock->routes->get(
            '/' => sub {
                my $c = shift;
                return $c->render(status => 200, text => "server is running");
            });

        # Connect application with web server and start accepting connections

        $daemon = Mojo::Server::Daemon->new(app => $mock, listen => [$host]);
        $daemon->start;

        Mojo::IOLoop->start if !Mojo::IOLoop->is_running;
        sleep 1 while !_port($port);

    }
}

sub stop_server {
    # now kill the worker
    kill TERM => $serverpid;
    sleep 1 while _port($port);
    is(waitpid($serverpid, 0), $serverpid, 'Server is done');
    $serverpid = undef;
}


chdir $ENV{LOGDIR};
get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');

my $autoinst_log = read_log('autoinst-log.txt');

like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 521/, "Asset download fails with connection refused";
truncate_log;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-404@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-404\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 404/, "Asset download fails with connection refused 404";
truncate_log;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-400@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-400\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 400/, "Asset download fails with connection refused 400";
truncate_log;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-500@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-500\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 500/, "Asset download fails with connection refused 500";
truncate_log;

get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
$autoinst_log = read_log('autoinst-log.txt');
like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-589\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/failed with: 589/, "Asset download fails with connection refused 589";
truncate_log;

stop_server;

done_testing();
