#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Mojo::Base -signatures;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Constants qw(DEFAULT_DOWNLOAD_REPO_TIMEOUT);
use OpenQA::Downloader;
use Mojo::Server::Daemon;
use Mojo::Log;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Utils qw(make_listen_url make_access_url to_plain_service_port);
use OpenQA::Test::Utils qw(fake_asset_server wait_for_or_bail_out);
use OpenQA::Test::TimeLimit '10';
use Mojo::File qw(path tempdir);
use Test::MockModule;

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


my $mojo_tmpdir = tempdir;
my $downloader = OpenQA::Downloader->new(log => $log, sleep_time => 0.05, attempts => 3, tmpdir => $mojo_tmpdir);
my $ua = $downloader->ua;
my $tempdir = tempdir;
my $to = $tempdir->child('test.qcow');
$ua->connect_timeout(0.25)->inactivity_timeout(0.25);

subtest 'Unable to create temporary directory' => sub {
    my $file_mock = Test::MockModule->new('Mojo::File');
    $file_mock->redefine(make_path => sub ($self) { die 'fake error' });
    like $downloader->download('from', 'to'), qr/temp.*dir.*fake error/, 'error returned';
};

subtest 'Connection refused' => sub {
    my $from = 'http://127.0.0.1:0/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-textmode@64bit.qcow2';
    like $downloader->download($from, $to), qr/Download of "$to" failed: Connection refused/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: Connection refused/, 'Real error is logged';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    unlike $cache_log, qr/Download error, waiting .* seconds for next try \(3 remaining\)/, 'only 3 attempts';
    $cache_log = '';
};

my $port = OpenQA::Utils::reserve_ports(['test'])->sockport;
my $host = make_access_url($port);
my $server_instance = process sub {
    # uncoverable statement
    Mojo::Server::Daemon->new(
        app => fake_asset_server,
        listen => [make_listen_url($port)],
        silent => $ENV{HARNESS_IS_VERBOSE} ? 0 : 1
    )->run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);    # uncoverable statement to ensure proper exit code of complete test at cleanup
  },
  max_kill_attempts => 0,
  blocking_stop => 1,
  _default_blocking_signal => POSIX::SIGTERM,
  kill_sleeptime => 0;
$server_instance->set_pipes(0)->start;
wait_for_or_bail_out { defined $ua->get($host)->res->code } 'worker';
sub stop_server () { $server_instance->stop() }

subtest 'Not found' => sub {
    my $from = "$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-404\@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 404 Not Found/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 404 Not Found/, 'Real error is logged';
    unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
    $cache_log = '';
};

subtest 'Success' => sub {
    my $from = "$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200\@64bit.qcow2";
    is $downloader->download($from, $to), undef, 'Success';

    ok -e $to, 'File downloaded';
    is -s $to, 1024, 'File size is 1024 bytes';
    unlink $to;

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
    $cache_log = '';
};

subtest 'Connection closed early' => sub {
    my $from = "$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200_close\@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: Premature connection close/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: Premature connection close/, 'Real error is logged';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Server error' => sub {
    my $from = "$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-200_server_error\@64bit.qcow2";
    like $downloader->download($from, $to), qr/Download of "$to" failed: 500 Internal Server Error/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Download of "$to" failed: 500 Internal Server Error/, 'Real error is logged';
    like $cache_log, qr/Download error 500, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error 500, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Size differs' => sub {
    my $from = "$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-589\@64bit.qcow2";
    like $downloader->download($from, $to), qr/Size of .* differs, expected \d+ Byte but downloaded \d+ Byte/, 'Failed';

    ok !-e $to, 'File not downloaded';

    like $cache_log, qr/Downloading "test.qcow" from "$from"/, 'Download attempt';
    like $cache_log, qr/Size of .+ differs, expected 10 Byte but downloaded 6 Byte/, 'Incomplete download logged';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    like $cache_log, qr/Download error, waiting .* seconds for next try \(1 remaining\)/, '1 tries remaining';
    $cache_log = '';
};

subtest 'Non-compressed files kept as-is - no complaint about unknown archive format' => sub {
    $to = $tempdir->child('test.txt');
    my $from = "$host/test";
    # don't check the error message as it is not interesting
    # (it's a generic error message that the archive is invalid)
    is $downloader->download($from, $to, {extract => 1}), undef, 'Success';
    ok -e $to, 'File downloaded';
    like $cache_log, qr/Downloading "test.txt" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*test" to ".*test.txt"/, 'Extracting download';
    is $to->slurp, 'This file was not compressed!', 'Contents extracted even though file was not compressed';
    $cache_log = '';
};

subtest 'Decompressing file' => sub {
    $to = $tempdir->child('test');
    my $from = "$host/test.gz";
    is $downloader->download($from, $to, {extract => 1}), undef, 'Success';
    ok -e $to, 'File downloaded and decompressed';
    is $to->slurp, 'This file was compressed!', 'File was decompressed';
    like $cache_log, qr/Downloading "test" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*test.gz" to ".*test"/, 'Extracting download';
    unlike $cache_log, qr/Extracting ".*test.*" failed:/, 'Extracting did not fail';
    $cache_log = '';
};

subtest 'Decompressing archive' => sub {
    $to = $tempdir->child('test');
    my $from = "$host/test.tar.xz";
    is $downloader->download($from, $to, {extract => 1}), undef, 'Success';
    ok -d $to, 'File downloaded, uncompressed and extracted';
    is $to->child('test-file')->slurp, "Archived file!\n", 'File was extracted';
    like $cache_log, qr/Downloading "test" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*test\.tar\.xz" to ".*test"/, 'Extracting download';
    unlike $cache_log, qr/Extracting ".*test.*" failed:/, 'Extracting did not fail';
    $cache_log = '';
};

subtest 'Error when decompressing archive' => sub {
    $to = $tempdir->child('fake-archive');
    my $from = "$host/fake-archive.tar.xz";
    like $downloader->download($from, $to, {extract => 1}), qr/Unrecognized archive format/, 'Failed';
    ok !-e $to, 'Target not created';
    like $cache_log, qr/Downloading "fake-archive" from "$from"/, 'Download attempt';
    like $cache_log, qr/Extracting ".*fake-archive\.tar\.xz" to ".*fake-archive"/, 'Extracting download';
    like $cache_log, qr/Extracting ".*fake-archive\.tar\.xz" failed:.*Unrecognized archive format.*/,
      'Extracting failed';
    $cache_log = '';
};

subtest 'Repository download with unsupported scheme' => sub {
    my $repo_dir = $tempdir->child('repo', 'myrepo');
    my $from = 'unsupported://example.com/myrepo';
    like $downloader->download($from, $repo_dir, {is_repo => 1}),
      qr/Unsupported URL scheme "unsupported" for repository download/, 'Unsupported scheme fails';
    ok !-e $repo_dir, 'Target repo not created';
    $cache_log = '';
};

subtest 'Repository download with rsync command execution' => sub {
    my $repo_dir = $tempdir->child('repo', 'rsyncrepo');
    my $from = 'rsync://example.com/repos/standard';
    my $called_cmd;
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            $called_cmd = $cmd;
            my $tmp_dest = $cmd->[-1];
            path($tmp_dest, 'repodata')->make_path->child('repomd.xml')->spurt('<repomd/>');
            return {status => 1, return_code => 0, exit_status => 0, stdout => '', stderr => ''};
        });
    is $downloader->download($from, $repo_dir, {exclude => '*.src.rpm,*-debuginfo*', timeout => 1800}), undef,
      'rsync download succeeds';
    ok -d $repo_dir, 'Repository directory created';
    ok -e $repo_dir->child('repodata', 'repomd.xml'), 'Repomd file exists in repo directory';
    is_deeply [splice @$called_cmd, 0, 8],
      [qw(rsync -avH --delete --timeout=1800 --exclude *.src.rpm --exclude *-debuginfo*)],
      'rsync command invoked correctly with excludes and timeout';
    $cache_log = '';
};

subtest 'Repository download with rsync link-dest deduplication' => sub {
    my $baseline = $tempdir->child('repo', 'fixed', 'standard-CURRENT');
    $baseline->make_path;
    my $repo_dir = $tempdir->child('repo', 'standard-Build1234');
    my $from = 'rsync://example.com/repos/standard';
    my $called_cmd;
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            $called_cmd = $cmd;
            my $tmp_dest = $cmd->[-1];
            path($tmp_dest, 'repodata')->make_path->child('repomd.xml')->spurt('<repomd/>');
            return {status => 1, return_code => 0, exit_status => 0, stdout => '', stderr => ''};
        });
    is $downloader->download($from, $repo_dir), undef, 'rsync download succeeds with auto link-dest';
    ok -d $repo_dir, 'Repository directory created';
    ok + (grep { $_ eq "--link-dest=$baseline" } @$called_cmd), 'auto link-dest passed to rsync';

    is $downloader->download($from, $repo_dir, {link_dest => 'standard-CURRENT'}), undef,
      'rsync download succeeds with explicit link-dest';
    ok + (grep { $_ eq "--link-dest=$baseline" } @$called_cmd), 'explicit link-dest passed to rsync';
    $cache_log = '';
};

subtest 'Repository download with rsync password file' => sub {
    my $pwd_file = $tempdir->child('rsync.secret');
    $pwd_file->spurt("secret\n");
    my $repo_dir = $tempdir->child('repo', 'authrepo');
    my $from = 'rsync://example.com/repos/standard';
    my $called_cmd;
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            $called_cmd = $cmd;
            my $tmp_dest = $cmd->[-1];
            path($tmp_dest, 'repodata')->make_path->child('repomd.xml')->spurt('<repomd/>');
            return {status => 1, return_code => 0, exit_status => 0, stdout => '', stderr => ''};
        });
    my $auth_downloader = OpenQA::Downloader->new(
        log => $log,
        tmpdir => $mojo_tmpdir,
        rsync_password_file => $pwd_file->to_string,
    );
    is $auth_downloader->download($from, $repo_dir), undef, 'rsync download succeeds with password file';
    ok -d $repo_dir, 'Repository directory created';
    ok + (grep { $_ eq "--password-file=$pwd_file" } @$called_cmd), 'password-file passed to rsync';
    $cache_log = '';
};

subtest 'Repository download with wget command execution' => sub {
    my $repo_dir = $tempdir->child('repo', 'httprepo');
    my $from = 'http://example.com/repos/openSUSE/standard/';
    my $called_cmd;
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            $called_cmd = $cmd;
            my $tmp_dest = $cmd->[-2];
            path($tmp_dest, 'repodata')->make_path->child('repomd.xml')->spurt('<repomd/>');
            return {status => 1, return_code => 0, exit_status => 0, stdout => '', stderr => ''};
        });
    is $downloader->download($from, $repo_dir, {exclude => '*.src.rpm,subdir/'}), undef, 'wget download succeeds';
    ok -d $repo_dir, 'Repository directory created';
    ok -e $repo_dir->child('repodata', 'repomd.xml'), 'Repomd file exists in repo directory';
    is $called_cmd->[4], '--cut-dirs=3', 'cut-dirs calculated correctly';
    ok + (grep { $_ eq '--timeout=' . DEFAULT_DOWNLOAD_REPO_TIMEOUT } @$called_cmd), 'default timeout passed to wget';
    ok + (grep { $_ eq '--reject' } @$called_cmd), 'reject flag passed for file pattern';
    ok + (grep { $_ eq '--exclude-directories' } @$called_cmd), 'exclude-directories flag passed for dir pattern';
    $cache_log = '';
};

subtest 'Repository download failure and cleanup' => sub {
    my $repo_dir = $tempdir->child('repo', 'failedrepo');
    my $from = 'http://example.com/repos/failed/';
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            return {
                status => 0,
                return_code => 8,
                exit_status => 8,
                stdout => '',
                stderr => 'ERROR 404: File not found.'
            };
        });
    like $downloader->download($from, $repo_dir), qr/ERROR 404: File not found/, 'Failed repo download reported';
    ok !-e $repo_dir, 'Failed repo target not created';
    $cache_log = '';
};

subtest 'Repository download server error 500 and retries' => sub {
    my $repo_dir = $tempdir->child('repo', 'retryrepo');
    my $from = 'http://example.com/repos/retry/';
    my $utils_mock = Test::MockModule->new('OpenQA::Utils');
    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            return {
                status => 0,
                return_code => 8,
                exit_status => 8,
                stdout => '',
                stderr => 'ERROR 500: Internal Server Error'
            };
        });
    like $downloader->download($from, $repo_dir), qr/ERROR 500: Internal Server Error/, 'Failed repo download reported';
    like $cache_log, qr/Download error 500, waiting .* seconds for next try \(2 remaining\)/, '2 tries remaining';
    $cache_log = '';
};

stop_server;

done_testing();
