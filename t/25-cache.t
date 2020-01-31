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

use Mojo::Base -strict;

my ($tempdir, $cached, $cachedir, $db_file);
BEGIN {
    use Mojo::File qw(path tempdir);

    $tempdir  = tempdir;
    $cached   = $tempdir->child('t', 'cache.d');
    $cachedir = path($cached, 'cache');
    $cachedir->remove_tree;
    $cachedir->make_path->realpath;
    $db_file = $cachedir->child('cache.sqlite');
    $ENV{OPENQA_CONFIG} = path($cached, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("
[global]
CACHEDIRECTORY = $cachedir
CACHEWORKERS = 10
CACHELIMIT = 50");
}

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Warnings;
use OpenQA::Utils qw(:DEFAULT base_host);
use OpenQA::CacheService;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::SQLite;
use Mojo::Log;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server);

my $port = Mojo::IOLoop::Server->generate_port;
my $host = "localhost:$port";

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
    Mojo::Server::Daemon->new(app => fake_asset_server, listen => ["http://$host"], silent => 1)->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->start;
    sleep 1 while !IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

my $app   = OpenQA::CacheService->new(log => $log);
my $cache = $app->cache;
is $cache->sqlite->migrations->latest, 2, 'version 2 is the latest version';
is $cache->sqlite->migrations->active, 2, 'version 2 is the active version';
like $cache_log, qr/Creating cache directory tree for "$cachedir"/,         'Cache directory tree created';
like $cache_log, qr/Cache size of "$cachedir" is 0 Byte, with limit 50GiB/, 'Cache limit is default (50GB)';
ok(-e $db_file, 'cache.sqlite is present');
$cache_log = '';

$cachedir->child('127.0.0.1')->make_path;
for my $i (1 .. 3) {
    my $file = $cachedir->child('127.0.0.1', "$i.qcow2")->spurt("\0" x 84);
    if ($i % 2) {
        my $sql = "INSERT INTO assets (filename,size, etag,last_use)
                VALUES ( ?, ?, 'Not valid', strftime('\%s','now'));";
        $cache->sqlite->db->query($sql, $file->to_string, 84);
    }
}

$cache->downloader->sleep_time(1);
$cache->init;
is $cache->sqlite->migrations->active, 2, 'version 2 is still the active version';
like $cache_log, qr/Cache size of "$cachedir" is 168 Byte, with limit 50GiB/,
  'Cache limit/size match the expected 100GB/168)';
unlike $cache_log, qr/Purging ".*[13].qcow2"/,                                  'Registered assets 1 and 3 were kept';
like $cache_log,   qr/Purging ".*2.qcow2" because the asset is not registered/, 'Asset 2 was removed';
$cache_log = '';

$cache->limit(100);
$cache->refresh;
like $cache_log, qr/Cache size of "$cachedir" is 84 Byte, with limit 100 Byte/,
  'Cache limit/size match the expected 100/84)';
like $cache_log, qr/Cache size 168 Byte \+ needed 0 Byte exceeds limit of 100 Byte, purging least used assets/,
  'Requested size is logged';
like $cache_log, qr/Purging ".*1.qcow2" because we need space for new assets, reclaiming 84/,
  'Oldest asset (1.qcow2) removal was logged';
ok(!-e '1.qcow2', 'Oldest asset (1.qcow2) was sucessfully removed');
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');
my $from = "http://$host/tests/922756/asset/hdd/sle-12-SP3-x86_64-0368-textmode@64bit.qcow2";
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2" from "$from"/, 'Asset download attempt';
like $cache_log, qr/failed: 521/, 'Asset download fails with: 521 Connection refused';
$cache_log = '';

$port = Mojo::IOLoop::Server->generate_port;
$host = "127.0.0.1:$port";
start_server;

$cache->limit(1024);
$cache->refresh;

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-404@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-404\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/failed: 404/, 'Asset download fails with: 404 Not Found';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-400@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-400\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/failed: 400/, 'Asset download fails with 400 Bad Request';
$cache_log = '';

# Retry server error (500)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_server_error@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_server_error\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*0368-200_server_error\@64bit.qcow2" failed: 500 Internal Server Error/,
  'Real error is logged';
like $cache_log, qr/Download error 500, waiting 1 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 500, waiting 1 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 500, waiting 1 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 500, waiting 1 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*qcow2" because of too many download errors/, 'Bailing out after too many retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_server_error@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Do not retry client error (404)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_client_error@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_client_error\@64bit.qcow2" from/,  'Asset download attempt';
like $cache_log, qr/Download of ".*0368-200_client_error\@64bit.qcow2" failed: 404 Not Found/, 'Real error is logged';
unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_client_error@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Retry download error with 200 status (size of asset differs)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-589\@64bit.qcow2" from/,         'Asset download attempt';
like $cache_log, qr/Size of .+ differs, expected 10 Byte but downloaded 6 Byte/,         'Incomplete download logged';
like $cache_log, qr/Download error 598, waiting 1 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 598, waiting 1 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 598, waiting 1 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 598, waiting 1 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*qcow2" because of too many download errors/, 'Bailing out after too many retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-589@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Retry connection error (closed early)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_close@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_close\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*200_close\@64bit.qcow2" failed: 521 Premature connection close/,
  'Real error is logged';
like $cache_log, qr/Download error 521, waiting 1 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 521, waiting 1 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 521, waiting 1 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 521, waiting 1 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*200_close\@64bit.qcow2" because of too many download errors/,
  'Bailing out after too many retries';
like $cache_log, qr/Purging ".*200_close\@64bit.qcow2" failed because the asset did not exist/, 'Asset was missing';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_close@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-503@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-503\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*0368-503\@64bit.qcow2" failed: 503 Service Unavailable/,
  'Asset download fails with 503 - Server not available';
like $cache_log, qr/Download error 503, waiting 1 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Purging ".*-503@64bit.qcow2" because of too many download errors/,
  'Bailing out after too many retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-503@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Successful download
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*sle-12-SP3-x86_64-0368-200.*" successful, new cache size is 1024/,
  'Full download logged';
like $cache_log, qr/Size of .* is 1024 Byte, with ETag "andi \$a3, \$t1, 41399"/, 'Etag and size are logged';
ok -e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200@64bit.qcow2'), 'Asset exist in cache';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/,             'Asset download attempt';
like $cache_log, qr/Content of ".*0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/,              'Asset download attempt';
like $cache_log, qr/Content of ".*-0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_256@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_256\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*sle-12-SP3-x86_64-0368-200_256.*" successful, new cache size is 256/,
  'Full download logged';
like $cache_log, qr/is 256 Byte, with ETag "andi \$a3, \$t1, 41399"/, 'Etag and size are logged';
like $cache_log, qr/Cache size 1024 Byte \+ needed 256 Byte exceeds limit of 1024 Byte, purging least used assets/,
  'Requested size is logged';
like $cache_log,
  qr/Purging ".*sle-12-SP3-x86_64-0368-200\@64bit.qcow2" because we need space for new assets, reclaiming 1024/,
  'Reclaimed space for new smaller asset';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_#:@64bit.qcow2');
like $cache_log, qr/Download of ".*sle-12-SP3-x86_64-0368-200_#:.*" successful/,
  'Asset with special characters was downloaded successfully';
like $cache_log, qr/Size of .* is 20 Byte, with ETag "123456789"/, 'Etag and size are logged';
$cache_log = '';

$cache->get_asset("http://$host", {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*sle-12-SP3-x86_64-0368-200.*" successful, new cache size is 1024/,
  'Full download logged';
like $cache_log, qr/Size of .* is 1024 Byte, with ETag "andi \$a3, \$t1, 41399"/, 'Etag and size are logged';
$cache_log = '';

$cache->get_asset("http://$host", {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/,             'Asset download attempt';
like $cache_log, qr/Content of ".*0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
$cache_log = '';

subtest 'track assets' => sub {
    $cache->sqlite->db->query('delete from assets');
    my $fake_asset = $cachedir->child('test.qcow2');
    $fake_asset->spurt('');
    ok -e $fake_asset, 'Asset is there';
    $cache->asset_lookup($fake_asset->to_string);
    ok !-e $fake_asset, 'Asset was purged since was not tracked';

    $fake_asset->spurt('');
    ok -e $fake_asset, 'Asset is there';
    $cache->purge_asset($fake_asset->to_string);
    ok !-e $fake_asset, 'Asset was purged';

    $cache->track_asset($fake_asset->to_string);
    is(ref($cache->asset($fake_asset->to_string)), 'HASH', 'Asset was just inserted, so it must be there')
      or die diag explain $cache->asset($fake_asset->to_string);

    is $cache->asset($fake_asset->to_string)->{etag}, undef, 'Can get downloading state with _asset()';
    is_deeply $cache->asset('foobar'), {}, 'asset() returns {} if asset is not present';
};

subtest 'cache directory is symlink' => sub {
    $cache->sqlite->db->query('delete from assets');
    $cache->init;
    $cache_log = '';

    my $symlink = $cached->child('symlink')->to_string;
    unlink($symlink);
    ok(symlink($cachedir, $symlink), "symlinking cache dir to $symlink");
    $cache->location($symlink);

    $cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
    like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
    like $cache_log, qr/Download of ".*sle-12-SP3-x86_64-0368-200.*" successful, new cache size is 1024/,
      'Full download logged';
    like $cache_log, qr/Size of .* is 1024 Byte, with ETag "andi \$a3, \$t1, 41399"/, 'Etag and size are logged';
    $cache_log = '';

    $cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
    like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
    like $cache_log, qr/Content of ".*0368-200@64bit.qcow2" has not changed, updating last use/,
      'Content has not changed';
    $cache_log = '';

    $cache->refresh;
    like $cache_log, qr/Cache size of "$cachedir" is 1024 Byte, with limit 1024 Byte/,
      'Cache limit/size match the expected 1024/1024)';
    $cache_log = '';

    $cache->limit(512)->refresh;
    like $cache_log, qr/Purging ".*200@64bit.qcow2" because we need space for new assets, reclaiming 1024 Byte/,
      'Reclaimed 1024 Byte';
    like $cache_log, qr/Cache size of "$cachedir" is 0 Byte, with limit 512 Byte/, 'Cache limit is 512 Byte';
    $cache_log = '';
};

subtest 'cache tmp directory is used for downloads' => sub {
    $cache->location($cachedir);
    my $tmpfile;
    $cache->downloader->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->res->on(
                progress => sub {
                    my $res = shift;
                    return unless $res->headers->content_length;
                    return unless $res->content->progress;
                    $tmpfile //= $res->content->asset->path;
                });
        });
    local $ENV{MOJO_MAX_MEMORY_SIZE} = 1;
    $cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
    is path($tmpfile)->dirname, path($cache->location, 'tmp'), 'cache tmp directory was used';
};

stop_server;

done_testing();
