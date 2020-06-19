#!/usr/bin/env perl
# Copyright (c) 2020 SUSE LLC
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

use Test::Most;

my $tempdir;
BEGIN {
    use Mojo::File qw(path tempdir);

    $ENV{OPENQA_CACHE_SERVICE_QUIET} = $ENV{HARNESS_IS_VERBOSE} ? 0 : 1;

    $tempdir = tempdir;
    my $basedir = $tempdir->child('t', 'cache.d');
    $ENV{OPENQA_CACHE_DIR} = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR}   = $basedir;
    $ENV{OPENQA_CONFIG}    = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt('
[global]
CACHEDIRECTORY = ' . $ENV{OPENQA_CACHE_DIR} . '
CACHEWORKERS = 10
CACHELIMIT = 100');
}

use OpenQA::CacheService;
use OpenQA::CacheService::Client;
use Mojo::Server::Daemon;
use Mojo::Log;
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

# Set up application and client
my $client = OpenQA::CacheService::Client->new;
my $app    = OpenQA::CacheService->new(log => $log);
my $daemon = Mojo::Server::Daemon->new(
    silent => 1,
    listen => ['http://127.0.0.1'],
    ioloop => $client->ua->ioloop,
    app    => $app
)->start;
my $host = 'http://127.0.0.1:' . $daemon->ports->[0];
$client->host($host);
like $cache_log, qr/Creating cache directory tree for/,             'directory initialized';
like $cache_log, qr/Cache size of .+ is 0 Byte, with limit 100GiB/, 'empty cache';

subtest 'Enqueue' => sub {
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    ok my $job = $app->minion->job($request->minion_id), 'is Minion job';
    is $job->task, 'cache_asset', 'right task';
    is_deeply $job->args, [9999, 'hdd', 'asset_name.qcow2', 'openqa.opensuse.org'], 'right arguments';

    $request = $client->rsync_request(from => '/test/a', to => '/test/b');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    ok $job = $app->minion->job($request->minion_id), 'is Minion job';
    is $job->task, 'cache_tests', 'right task';
    is_deeply $job->args, ['/test/a', '/test/b'], 'right arguments';
};

subtest 'Enqueue error' => sub {
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    $request->task(undef);
    like $client->enqueue($request), qr/Cache service enqueue error from API: No task defined/, 'error';
    ok !$request->minion_id, 'no Minion id';

    $request = $client->rsync_request(from => '/test/a', to => '/test/b');
    $request->task(undef);
    like $client->enqueue($request), qr/Cache service enqueue error from API: No task defined/, 'error';
    ok !$request->minion_id, 'no Minion id';

    my $mock = Test::MockModule->new('OpenQA::CacheService::Request::Asset');
    $mock->redefine(to_array => sub { undef });
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error from API: No arguments defined/, 'error';
    ok !$request->minion_id, 'no Minion id';

    $mock->redefine(to_array => sub { 'test' });
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error from API: Arguments need to be an array/, 'error';
    ok !$request->minion_id, 'no Minion id';

    $mock->unmock('to_array');
    $mock->redefine(lock => sub { undef });
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error from API: No lock defined/, 'error';
    ok !$request->minion_id, 'no Minion id';

    $mock->unmock('lock');
    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!', status => 500) });
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error 500: Internal Server Error/, 'error';
    ok !$request->minion_id, 'no Minion id';

    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!') });
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error: 200 non-JSON response/, 'error';
    ok !$request->minion_id, 'no Minion id';
};

done_testing();
