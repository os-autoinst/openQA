#! /usr/bin/perl

# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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

use Data::Dump qw(pp dd);
use File::Path qw(remove_tree make_path);
use File::Spec::Functions 'catfile';
use Digest::MD5 qw(md5);

use Cwd qw(abs_path getcwd);
use File::Spec::Functions 'catdir';

# create Test DBus bus and service for fake WebSockets call
# my $ws = OpenQA::WebSockets->new;


my $sql;
my $sth;
my $result;
my $dbh;
my $filename;

my $cachedir = catdir(getcwd(), 't/cache.d/cache');
my $db_file = "$cachedir/cache.sqlite";
$ENV{LOGDIR} = catdir(getcwd(), 't/cache.d', 'logs');
my $logfile = catdir($ENV{LOGDIR}, 'cache.log');
my $host = 'http://localhost';


remove_tree($cachedir);
make_path($ENV{LOGDIR});

#redirect stdout
open(my $FD, '>>', $logfile);
select $FD;
$| = 1;
truncate_log();
# Mock of log_* methods used by Cache:

my $module = new Test::MockModule('OpenQA::Utils');
#log_error log_info log_debug

$module->mock(log_info  => \&mock_log_info);
$module->mock(log_error => \&mock_log_error);
$module->mock(log_debug => \&mock_log_debug);
$module->mock(delete    => \&mock_delete);

# logging helpers
sub mock_log_debug {
    my ($msg) = @_;
    print "[DEBUG] $msg\n";
}

sub mock_log_info {
    my ($msg) = @_;
    print "[INFO] $msg\n";
}

sub mock_log_error {
    my ($msg) = @_;
    print "[ERROR] $msg\n";
}

sub truncate_log {
    truncate $FD, 0;
}


sub read_log {
    my ($new_log) = @_;
    my $logfile_ = ($new_log) ? $new_log : $logfile;
    open(my $f, '<', $logfile_) or die "OPENING $logfile_: $!\n";
    my $log = do { local ($/); <$f> };
    close($f);
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

$OpenQA::Worker::Cache::limit = 1000;
OpenQA::Worker::Cache::init($host, $cachedir);

unlike read_log, qr/Deploying DB/, "Cache deploys the database.";
like read_log, qr/CACHE: Health: Real size: 168, Configured limit: 1000/,
  "Cache limit/size match the expected 1000/168)";
unlike read_log, qr/CACHE: Purging non registered.*[13].qcow2/, "Registered assets 1 and 3 were kept";
like read_log,   qr/CACHE: Purging non registered.*2.qcow2/,    "Asset 2 was removed";
truncate_log;

$OpenQA::Worker::Cache::limit = 100;
OpenQA::Worker::Cache::init($host, $cachedir);

like read_log, qr/CACHE: Health: Real size: 84, Configured limit: 100/, "Cache limit/size match the expected 100/84)";
like read_log, qr/CACHE: removed.*1.qcow2/, "Oldest asset (1.qcow2) removal was logged";
ok(!-e "$cachedir/1.qcow2", "Oldest asset (1.qcow2) was sucessfully removed");
truncate_log;

chdir $ENV{LOGDIR};
get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');

my $autoinst_log = read_log('autoinst-log.txt');

like $autoinst_log, qr/Downloading sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2 from/, "Asset download attempt";
like $autoinst_log, qr/sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2.*refused/,
  "Asset download fails with connection refused";

remove_tree($cachedir);
done_testing();
