#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

my ($tempdir, $cached, $cachedir, $db_file);
BEGIN {
    use Mojo::File qw(path tempdir);

    $tempdir = tempdir;
    $cached = $tempdir->child('t', 'cache.d');
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

    # make test independent of the journaling setting
    delete $ENV{OPENQA_CACHE_SERVICE_SQLITE_JOURNAL_MODE};
}

use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;

use Carp 'croak';
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::Mojo;
use OpenQA::Utils qw(:DEFAULT base_host);
use OpenQA::CacheService;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::SQLite;
use Mojo::Log;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use IPC::Run qw(start);
use OpenQA::Test::Utils qw(fake_asset_server stop_service wait_for_or_bail_out);
use OpenQA::Test::TimeLimit '30';

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

END { session->clean }

my $server_instance;

sub start_server {
    $server_instance = start sub {
        Mojo::Server::Daemon->new(app => fake_asset_server, listen => ["http://$host"], silent => 1)->run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);    # uncoverable statement to ensure proper exit code of complete test at cleanup
    };
    wait_for_or_bail_out { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) } 'cache service';
}

END { stop_service($server_instance) }

my $app = OpenQA::CacheService->new(log => $log);
my $cache = $app->cache;
is $cache->sqlite->migrations->latest, 4, 'version 4 is the latest version';
is $cache->sqlite->migrations->active, 4, 'version 4 is the active version';
like $cache_log, qr/Creating cache directory tree for "$cachedir"/, 'Cache directory tree created';
like $cache_log, qr/Cache size of "$cachedir" is 0 Byte, with limit 50 GiB/, 'Cache limit is default (50GB)';
ok(-e $db_file, 'cache.sqlite is present');
$cache_log = '';

# create three assets (1 and 3: registered and not pending; 2: not registered)
my $local_cache_dir = $cachedir->child('127.0.0.1');
$local_cache_dir->make_path;
for my $i (1 .. 3) {
    my $file = $local_cache_dir->child("$i.qcow2")->spurt("\0" x 84);
    if ($i % 2) {
        my $sql = "INSERT INTO assets (filename,size, etag, last_use, pending)
                VALUES ( ?, ?, 'Not valid', strftime('\%s','now'), 0);";
        $cache->sqlite->db->query($sql, $file->to_string, 84);
    }
}
# create pending asset
$local_cache_dir->child('4.qcow2')->touch;
$cache->sqlite->db->query(
    "INSERT INTO assets (filename,size, etag, last_use)
                VALUES ( '4.qcow2', 42, 'Not valid', strftime('\%s','now'));"
);

# initialize the cache
$cache->downloader->sleep_time(0.01);
$cache->init;
$cache->limit(100);
is $cache->sqlite->migrations->active, 4, 'version 4 is still the active version';
like $cache_log, qr/Cache size of "$cachedir" is 168 Byte, with limit 50 GiB/,
  'Cache limit/size match the expected 100GB/168)';
unlike $cache_log, qr/Purging ".*[13].qcow2"/, 'Registered assets 1 and 3 were kept';
like $cache_log, qr/Purging ".*2.qcow2" because the asset is not registered/, 'Unregistered asset 2 was removed';
like $cache_log, qr/Purging ".*4.qcow2" because it appears pending/, 'Pending asset 4 was removed';
ok !-e $local_cache_dir->child('2.qcow2');
ok !-e $local_cache_dir->child('4.qcow2');
$cache_log = '';

# assume asset 3 is pending; it should be preserved by the next test
my $pending_asset = $local_cache_dir->child('3.qcow2');
$cache->sqlite->db->query('UPDATE assets set pending = 1 where filename = ?', $pending_asset->to_string);

# run the cleanup specifying that the oldest asset (which would otherwise be deleted) should be preserved
my $oldest_asset = $local_cache_dir->child('1.qcow2');
$cache->_check_limits(0, {$oldest_asset => 1});
ok -e $oldest_asset, 'specified asset has been preserved';
ok -e $pending_asset, 'pending asset has been preserved';
$cache_log = '';

# assume asset 3 is no longer pending; it should nevertheless be preserved by the next test because it isn't the oldest
$cache->sqlite->db->query('UPDATE assets set pending = 0 where filename = ?', $pending_asset->to_string);

# run the cleanup again without preserving the oldest asset
$cache->refresh;
like $cache_log, qr/Cache size of "$cachedir" is 84 Byte, with limit 100 Byte/,
  'Cache limit/size match the expected 100/84)';
like $cache_log, qr/Cache size 168 Byte \+ needed 0 Byte exceeds limit of 100 Byte, purging least used assets/,
  'Requested size is logged';
like $cache_log, qr/Purging ".*1.qcow2" because we need space for new assets, reclaiming 84/,
  'Oldest asset (1.qcow2) removal was logged';
ok !-e $oldest_asset, 'Oldest asset (1.qcow2) was successfully removed';
ok -e $pending_asset, 'Not so old asset (3.qcow2) was preserved (despite not being pending anymore)';
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
like $cache_log, qr/Download error 500, waiting 0.01 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 500, waiting 0.01 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 500, waiting 0.01 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 500, waiting 0.01 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*qcow2" because of too many download errors/, 'Bailing out after too many retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_server_error@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Do not retry client error (404)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_client_error@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_client_error\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*0368-200_client_error\@64bit.qcow2" failed: 404 Not Found/, 'Real error is logged';
unlike $cache_log, qr/waiting .* seconds for next try/, 'No retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_client_error@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Retry download error with 200 status (size of asset differs)
my $old_timeout = $cache->downloader->ua->inactivity_timeout;
$cache->downloader->ua->inactivity_timeout(0.5);
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
$cache->downloader->ua->inactivity_timeout($old_timeout);
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-589\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Size of .+ differs, expected 10 Byte but downloaded 6 Byte/, 'Incomplete download logged';
like $cache_log, qr/Download error 598, waiting 0.01 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 598, waiting 0.01 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 598, waiting 0.01 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 598, waiting 0.01 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*qcow2" because of too many download errors/, 'Bailing out after too many retries';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-589@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

# Retry connection error (closed early)
$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200_close@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200_close\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*200_close\@64bit.qcow2" failed: 521 Premature connection close/,
  'Real error is logged';
like $cache_log, qr/Download error 521, waiting 0.01 seconds for next try \(4 remaining\)/, '4 tries remaining';
like $cache_log, qr/Download error 521, waiting 0.01 seconds for next try \(3 remaining\)/, '3 tries remaining';
like $cache_log, qr/Download error 521, waiting 0.01 seconds for next try \(2 remaining\)/, '2 tries remaining';
like $cache_log, qr/Download error 521, waiting 0.01 seconds for next try \(1 remaining\)/, '1 tries remaining';
like $cache_log, qr/Purging ".*200_close\@64bit.qcow2" because of too many download errors/,
  'Bailing out after too many retries';
like $cache_log, qr/Purging ".*200_close\@64bit.qcow2" failed because the asset did not exist/, 'Asset was missing';
ok !-e $cachedir->child($host, 'sle-12-SP3-x86_64-0368-200_close@64bit.qcow2'), 'Asset does not exist in cache';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-503@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-503\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Download of ".*0368-503\@64bit.qcow2" failed: 503 Service Unavailable/,
  'Asset download fails with 503 - Server not available';
like $cache_log, qr/Download error 503, waiting 0.01 seconds for next try \(4 remaining\)/, '4 tries remaining';
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
is $cache->asset($cachedir->child($host, 'sle-12-SP3-x86_64-0368-200@64bit.qcow2')->to_string)->{pending}, 0,
  'Pending flag unset after download';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Content of ".*0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
$cache_log = '';

$cache->get_asset($host, {id => 922756}, 'hdd', 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Content of ".*-0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
$cache_log = '';

subtest 'cache purging after successful download' => sub {
    my $asset = 'sle-12-SP3-x86_64-0368-200_256@64bit.qcow2';
    my $cache_mock = Test::MockModule->new('OpenQA::CacheService::Model::Cache');
    $cache_mock->redefine(
        _check_limits => sub ($self, $needed, $to_preserve) {
            is($needed, 256, 'correct number of bytes would be freed');
            like(join('', keys %$to_preserve), qr/$asset$/, 'downloaded asset would have been preserved')
              or diag explain $to_preserve;
            $cache_mock->original('_check_limits')->($self, $needed, $to_preserve);
        });
    $cache->get_asset($host, {id => 922756}, 'hdd', $asset);
    like $cache_log, qr/Downloading "$asset" from/, 'Asset download attempt';
    like $cache_log, qr/Download of ".*$asset.*" successful, new cache size is 256/, 'Full download logged';
    like $cache_log, qr/is 256 Byte, with ETag "andi \$a3, \$t1, 41399"/, 'Etag and size are logged';
    like $cache_log, qr/Cache size 1024 Byte \+ needed 256 Byte exceeds limit of 1024 Byte, purging least used assets/,
      'Requested size is logged';
    like $cache_log,
      qr/Purging ".*sle-12-SP3-x86_64-0368-200\@64bit.qcow2" because we need space for new assets, reclaiming 1024/,
      'Reclaimed space for new smaller asset';
    $cache_log = '';
    undef $cache_mock;
};

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
like $cache_log, qr/Downloading "sle-12-SP3-x86_64-0368-200\@64bit.qcow2" from/, 'Asset download attempt';
like $cache_log, qr/Content of ".*0368-200@64bit.qcow2" has not changed, updating last use/, 'Content has not changed';
is $cache->asset($cachedir->child(base_host("http://$host"), 'sle-12-SP3-x86_64-0368-200@64bit.qcow2'))->{pending}, 0,
  'Pending flag unset if asset unchanged';
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
    is $cache->asset($fake_asset->to_string)->{pending}, 1, 'New asset is pending';

    $cache->_update_asset_last_use($fake_asset->to_string);
    is $cache->asset($fake_asset->to_string)->{pending}, 0, 'Asset no longer pending when updated';

    $cache->track_asset($fake_asset->to_string);
    is $cache->asset($fake_asset->to_string)->{pending}, 1, 'Re-tracked asset treated as pending again';

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

subtest 'cache directory is corrupted' => sub {
    my $tempdir = tempdir;
    my $cache_dir = $tempdir->child('cache')->make_path;
    local $ENV{OPENQA_CACHE_DIR} = $cache_dir->to_string;
    my $db_file = $cache_dir->child('cache.sqlite');

    # New cache dir, force using WAL journaling mode
    $ENV{OPENQA_CACHE_SERVICE_SQLITE_JOURNAL_MODE} = 'wal';
    $cache_log = '';
    my $app = OpenQA::CacheService->new(log => $log);
    my $cache = $app->cache;
    ok -e $db_file, 'database exists';
    ok -e $db_file->sibling('cache.sqlite-wal'), 'WAL journaling mode enabled';
    like $cache_log, qr/Creating cache directory tree for "\Q$cache_dir\E/, 'created';
    ok $cache->sqlite->migrations->latest > 1, 'migration active';
    $app->cache->sqlite->db->disconnect;
    delete $ENV{OPENQA_CACHE_SERVICE_SQLITE_JOURNAL_MODE};

    # Cache dir exists, switch back to DELETE journaling mode
    $cache_log = '';
    $app = OpenQA::CacheService->new(log => $log);
    ok -e $db_file, 'database exists';
    ok !-e $db_file->sibling('cache.sqlite.sqlite-wal'), 'no WAL file created';
    unlike $cache_log, qr/Creating cache directory tree for "\Q$cache_dir\E/, 'not created again';
    ok $app->cache->sqlite->migrations->latest > 1, 'migration active';

    # Removed SQLite file
    $app = OpenQA::CacheService->new(log => $log);
    $cache_log = '';
    $app->cache->sqlite->db->disconnect;
    $db_file->remove;
    ok !-e $db_file, 'database exists not';
    $app->cache->init;
    ok -e $db_file, 'database exists';
    like $cache_log, qr/Creating cache directory tree for "\Q$cache_dir\E/, 'recreated';
    ok $app->cache->sqlite->migrations->latest > 1, 'migration active';

    my $cache_mock = Test::MockModule->new('OpenQA::CacheService::Model::Cache');
    $cache_mock->redefine(
        _kill_db_accessing_processes => sub {
            my ($self, @db_files) = @_;
            note 'Simulating killing PIDs accessing the DB: ' . join ' ', @db_files;
        });

    # Integrity checks fails
    $cache_mock->redefine(_perform_integrity_check => sub { [qw(foo bar)] });
    $cache_log = '';
    $app->cache->sqlite->db->disconnect;
    $app->cache->init;
    like $cache_log, qr/Database integrity check found errors.*foo.*bar/s, 'integrity check';
    like $cache_log, qr/Killing processes.*and removing database/, 'killing db processes, removing db';
    undef $cache_mock;

    # Service stopped after fatal database error
    my $api_mock = Test::MockModule->new('OpenQA::CacheService::Controller::API');
    $api_mock->redefine(enqueue => sub { croak 'DBD::SQLite::st execute failed: database disk image is malformed' });
    my $t = Test::Mojo->new('OpenQA::CacheService');
    $t->app->log($log);
    $cache_log = '';
    $t->post_ok('/enqueue')->status_is(500);
    like $cache_log, qr/database disk image is malformed.*Stopping service.*/s, 'service stopped after fatal db error';
    is $t->app->exit_code, 1, 'non-zero return code';
};

subtest 'checking limits' => sub {
    my $df_mock = Test::MockModule->new('Filesys::Df', no_auto => 1);
    $df_mock->redefine(df => {bavail => 100, blocks => 1000});

    $cache->limit(0)->min_free_percentage(0);
    is $cache->_exceeds_limit(5000), 0, 'limits not exceeded when none specified';

    $cache->limit(6000);
    is $cache->_exceeds_limit(1000), 0, 'limits not exceeded as current size + needed size below limit';
    is $cache->_exceeds_limit(5000), 1, 'limits exceeded as current size + needed size exceeds limit';

    $cache->limit(0)->min_free_percentage(20);
    is $cache->_exceeds_limit(100), 0, 'limits not exceeded with enough free disk space';
    is $cache->_exceeds_limit(101), 1, 'limits exceeded when not enough free disk space';

    $df_mock->redefine(df => {});
    $cache_log = '';
    is $cache->_exceeds_limit(101), 0, 'limit ignored when free disk space cannot be determined';
    like $cache_log, qr/.*Unable to determine disk usage of.*/,
      'warning shown when free disk space cannot be determined';
};

done_testing();
