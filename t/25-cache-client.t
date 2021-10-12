#!/usr/bin/env perl
# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

my $sleep_count = 0;
my $tempdir;
BEGIN {
    use Mojo::File qw(path tempdir);

    $ENV{OPENQA_CACHE_SERVICE_QUIET} = $ENV{HARNESS_IS_VERBOSE} ? 0 : 1;

    $tempdir = tempdir;
    my $basedir = $tempdir->child('t', 'cache.d');
    $ENV{OPENQA_CACHE_DIR} = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR} = $basedir;
    $ENV{OPENQA_CONFIG} = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt('
[global]
CACHEDIRECTORY = ' . $ENV{OPENQA_CACHE_DIR} . '
CACHEWORKERS = 10
CACHELIMIT = 100');

    *CORE::GLOBAL::sleep = sub { $sleep_count++ };
}

use OpenQA::CacheService;
use OpenQA::CacheService::Client;
use Mojo::Server::Daemon;
use Mojo::Log;
use Test::MockModule;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';

# Set up application and client
my $client = OpenQA::CacheService::Client->new;
my $log = Mojo::Log->new(level => 'error');
my $app = OpenQA::CacheService->new(log => $log);
my $daemon = Mojo::Server::Daemon->new(
    silent => 1,
    listen => ['http://127.0.0.1'],
    ioloop => $client->ua->ioloop,
    app => $app
)->start;
$client->host("http://127.0.0.1:$daemon->ports->[0]")->set_port($daemon->ports->[0]);

sub _refuse_connection {
    my ($ua, $tx) = @_;
    my $port = Mojo::IOLoop::Server->generate_port;
    $client->set_port($port);
    $tx->req->url->port($port);
}

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

subtest 'Enqueue error (with retry)' => sub {
    is $client->sleep_time, 5, 'correct number of seconds by default';
    is $client->attempts, 60, 'correct attempts by default';

    my $cb = $client->ua->on(start => \&_refuse_connection);
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    like $client->enqueue($request), qr/Cache service enqueue error: Connection refused/, 'error';
    $client->ua->unsubscribe(start => $cb);
    is $sleep_count, $client->attempts - 1, 'sleep called multiple times';
    ok !$request->minion_id, 'no Minion id';

    $sleep_count = 0;
    $cb = $client->ua->once(start => \&_refuse_connection);
    $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    is $sleep_count, 1, 'sleep called once';
    ok $request->minion_id, 'has Minion id';
    ok my $job = $app->minion->job($request->minion_id), 'is Minion job';
    is $job->task, 'cache_asset', 'right task';
    is_deeply $job->args, [9999, 'hdd', 'asset_name.qcow2', 'openqa.opensuse.org'], 'right arguments';
};

subtest 'Info' => sub {
    my $info = $client->info;
    ok !$info->error, 'no error';
    ok $info->availability_error, 'no error';
    ok $info->available, 'available';
    ok !$info->available_workers, 'no available workers';
    is $info->availability_error, 'No workers active in the cache service', 'availability error';

    my $worker = $app->minion->worker->register;
    $info = $client->info;
    ok !$info->error, 'no error';
    ok $info->available, 'available';
    ok $info->available_workers, 'available workers';
    ok !$info->availability_error, 'no availability error';
    $worker->unregister;
};

subtest 'Info error' => sub {
    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!', status => 500) });
    my $info = $client->info;
    is $info->error, 'Cache service info error 500: Internal Server Error', 'right error';
    ok $info->availability_error, 'error';
    ok !$info->available, 'not available';
    ok !$info->available_workers, 'no available workers';
    is $info->availability_error, 'Cache service info error 500: Internal Server Error', 'availability error';

    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!') });
    $info = $client->info;
    is $info->error, 'Cache service info error: 200 non-JSON response', 'right error';
    ok $info->availability_error, 'error';
    ok !$info->available, 'not available';
    ok !$info->available_workers, 'no available workers';
    is $info->availability_error, 'Cache service info error: 200 non-JSON response', 'availability error';
};

subtest 'Info error (with retry)' => sub {
    $sleep_count = 0;
    my $cb = $client->ua->on(start => \&_refuse_connection);
    my $info = $client->info;
    $client->ua->unsubscribe(start => $cb);
    is $sleep_count, $client->attempts - 1, 'sleep called multiple times';
    like $info->error, qr/Cache service info error: Connection refused/, 'right error';

    $sleep_count = 0;
    $cb = $client->ua->once(start => \&_refuse_connection);
    $info = $client->info;
    is $sleep_count, 1, 'sleep called once';
    ok !$info->error, 'no error';
    ok $info->availability_error, 'no error';
    ok $info->available, 'available';
    ok !$info->available_workers, 'no available workers';
    is $info->availability_error, 'No workers active in the cache service', 'availability error';
};

subtest 'Status' => sub {
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    my $status = $client->status($request);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, undef, 'no output';

    my $request2
      = $client->asset_request(id => 9998, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request2), 'no error';
    ok $request2->minion_id, 'has Minion id';
    $status = $client->status($request2);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, undef, 'no output';

    # Two concurrent jobs downloading the same file
    my $worker = $app->minion->worker->register;
    my $job = $worker->dequeue(0, {id => $request->minion_id});
    ok my $guard = $app->progress->guard($request->lock, $request->minion_id), 'lock acquired';
    $status = $client->status($request);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    ok !$status->is_processed, 'not processed';
    my $job2 = $worker->dequeue(0, {id => $request2->minion_id});
    $job2->perform;
    $status = $client->status($request2);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, undef, 'no output';

    # Download finished
    undef $guard;
    ok $job->finish('Test finish'), 'finished';
    ok $job->note(output => "it\nworks\n!"), 'noted';
    $status = $client->status($request);
    ok !$status->error, 'no error';
    ok !$status->is_downloading, 'not downloading';
    ok $status->is_processed, 'processed';
    is $status->result, 'Test finish', 'result';
    is $status->output, "it\nworks\n!", 'output';

    # Output from a different job
    $status = $client->status($request2);
    ok !$status->error, 'no error';
    ok !$status->is_downloading, 'not downloading';
    ok $status->is_processed, 'processed';
    is $status->result, undef, 'no result';
    is $status->output, "it\nworks\n!", 'output';
    is $job2->info->{notes}{output},
      'Asset "asset_name.qcow2" was downloaded by #4, details are therefore unavailable here', 'different output';

    # Remove the job that actually performed the download
    ok $app->minion->job($request->minion_id)->remove, 'removed';
    $status = $client->status($request2);
    ok !$status->error, 'no error';
    ok !$status->is_downloading, 'not downloading';
    ok $status->is_processed, 'processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Asset "asset_name.qcow2" was downloaded by #4, details are therefore unavailable here',
      'output';
    $worker->unregister;
};

subtest 'Status error' => sub {
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!', status => 500) });
    my $status = $client->status($request);
    is $status->error, 'Cache service status error 500: Internal Server Error', 'right error';
    ok !$status->is_downloading, 'not downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Cache service status error 500: Internal Server Error', 'output';

    $app->plugins->once(before_dispatch => sub { shift->render(text => 'Howdy!') });
    $status = $client->status($request);
    is $status->error, 'Cache service status error: 200 non-JSON response', 'right error';
    ok !$status->is_downloading, 'not downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Cache service status error: 200 non-JSON response', 'output';

    ok $app->minion->job($request->minion_id)->remove, 'removed';
    $status = $client->status($request);
    is $status->error, 'Cache service status error from API: Specified job ID is invalid', 'right error';
    ok !$status->is_downloading, 'not downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Cache service status error from API: Specified job ID is invalid', 'output';

    # Single job failure
    $request = $client->asset_request(
        id => 9997,
        asset => 'another_asset.qcow2',
        type => 'hdd',
        host => 'openqa.opensuse.org'
    );
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    my $worker = $app->minion->worker->register;
    my $job = $worker->dequeue(0, {id => $request->minion_id});
    $job->fail('Just a test');
    $status = $client->status($request);
    is $status->error, 'Cache service status error from API: Minion job #7 failed: Just a test', 'right error';
    ok !$status->is_downloading, 'not downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Cache service status error from API: Minion job #7 failed: Just a test', 'output';

    # Concurrent jobs failure
    $request = $client->asset_request(id => 9995, asset => 'asset.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    my $request2
      = $client->asset_request(id => 9994, asset => 'asset.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request2), 'no error';
    ok $request2->minion_id, 'has Minion id';
    $job = $worker->dequeue(0, {id => $request->minion_id});
    ok my $guard = $app->progress->guard($request->lock, $request->minion_id), 'lock acquired';
    $status = $client->status($request);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    my $job2 = $worker->dequeue(0, {id => $request2->minion_id});
    $job2->perform;
    $status = $client->status($request2);
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    undef $guard;
    ok $job->fail('Just another test'), 'finished';
    ok $job->note(output => "it\nworks\ntoo!"), 'noted';
    $status = $client->status($request);
    is $status->error, 'Cache service status error from API: Minion job #8 failed: Just another test', 'right error';
    ok !$status->is_downloading, 'not downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, 'Cache service status error from API: Minion job #8 failed: Just another test', 'output';
    $worker->unregister;
};

subtest 'Status error (with retry)' => sub {
    $sleep_count = 0;
    my $request
      = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    ok !$client->enqueue($request), 'no error';
    ok $request->minion_id, 'has Minion id';
    my $cb = $client->ua->on(start => \&_refuse_connection);
    my $status = $client->status($request);
    is $sleep_count, $client->attempts - 1, 'sleep called multiple times';
    $client->ua->unsubscribe(start => $cb);
    like $status->error, qr/Cache service status error: Connection refused/, 'right error';

    $sleep_count = 0;
    $cb = $client->ua->once(start => \&_refuse_connection);
    $status = $client->status($request);
    is $sleep_count, 1, 'sleep called once';
    ok !$status->error, 'no error';
    ok $status->is_downloading, 'downloading';
    ok !$status->is_processed, 'not processed';
    is $status->result, undef, 'no result';
    is $status->output, undef, 'no output';
};

done_testing();
