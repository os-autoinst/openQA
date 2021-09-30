#!/usr/bin/env perl

# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Downloader;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::Log;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server wait_for_or_bail_out);
use OpenQA::Test::TimeLimit '10';
use Mojo::File qw(tempdir);

my $port = Mojo::IOLoop::Server->generate_port;
my $host = "127.0.0.1:$port";

# avoid cluttering log with warnings from the Archive::Extract module
$Archive::Extract::WARN = 0;

# Capture logs
my $log = Mojo::Log->new;
$log->unsubscribe('message');
my $cache_log = '';
$log->on(
    message => sub {
        my ($log, $level, @lines) = @_;
        $cache_log .= "[$level] " . join "\n", @lines, '';
    });

$SIG{INT} = sub { session->clean };

END { session->clean }

my $server_instance = process sub {
    # uncoverable statement
    Mojo::Server::Daemon->new(app => fake_asset_server, listen => ["http://$host"], silent => 1)->run;
    _exit(0);    # uncoverable statement to ensure proper exit code of complete test at cleanup
  },
  max_kill_attempts => 0,
  blocking_stop => 1,
  _default_blocking_signal => POSIX::SIGTERM,
  kill_sleeptime => 0;

sub start_server {
    $server_instance->set_pipes(0)->start;
    wait_for_or_bail_out { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) } 'worker';
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

my $mojo_tmpdir = tempdir;
my $downloader = OpenQA::Downloader->new(log => $log, sleep_time => 0.05, attempts => 3, tmpdir => $mojo_tmpdir);
my $ua = $downloader->ua;
my $tempdir = tempdir;
my $to = $tempdir->child('test.qcow');

$ua->connect_timeout(0.25)->inactivity_timeout(0.25);

subtest 'Connection refused' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-textmode@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 521/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 521/, 'Real error is logged';
    like $cache_log, qr/Download error 521, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error 521, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    unlike $cache_log, qr/Download error 521, waiting .* seconds for next try \(3 remaining\)/, 'only 3 attempts';
    $cache_log = '';
};

$port = Mojo::IOLoop::Server->generate_port;
$host = "127.0.0.1:$port";
start_server;

subtest 'Not found' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-404@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 404 Not Found/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 404 Not Found/, 'Real error is logged';
    unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
    $cache_log = '';
};

subtest 'Success' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200@64bit.qcow2";
    is $downloader->download($from, $to), undef, 'Success';

    ok -e $to, 'File downloaded';
    is -s $to, 1024, 'File size is 1024 bytes';
    unlink $to;

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
    $cache_log = '';
};

subtest 'Connection closed early' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200_close@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 521 Premature connection close/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 521 Premature connection close/, 'Real error is logged';
    like $cache_log, qr/Download error 521, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error 521, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Server error' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200_server_error@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 500 Internal Server Error/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 500 Internal Server Error/, 'Real error is logged';
    like $cache_log, qr/Download error 500, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error 500, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Size differs' => sub {
    my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-589@64bit.qcow2";
    like $downloader->download($from, $to), qr/Size of .* differs, expected \d+ Byte but downloaded \d+ Byte/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Size of .+ differs, expected 10 Byte but downloaded 6 Byte/, 'Incomplete download logged';
    like $cache_log, qr/Download error 598, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error 598, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Decompressing archive failed' => sub {
    $to = $tempdir->child('test.gz');
    my $from = "http://$host/test";
    # don't check the error message as it is not interesting
    # (it's a generic error message that the archive is invalid)
    ok defined($downloader->download($from, $to, {extract => 1})), 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.gz" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*test" to ".*test.gz"/, 'Extracting download';
    like $cache_log, qr/Extracting ".*test" failed: Could not determine archive type/, 'Extracting failed';
    $cache_log = '';
};

subtest 'Decompressing archive' => sub {
    $to = $tempdir->child('test');
    my $from = "http://$host/test.gz";
    is $downloader->download($from, $to, {extract => 1}), undef, 'Success';

    ok -e $to, 'File downloaded';
    is $to->slurp, 'This file was compressed!', 'File was decompressed';

    like $cache_log, qr/Downloading "test" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*test.gz" to ".*test"/, 'Extracting download';
    unlike $cache_log, qr/Extracting ".*test.gz" failed:/, 'Extracting did not fail';
    $cache_log = '';
};

stop_server;

done_testing();
