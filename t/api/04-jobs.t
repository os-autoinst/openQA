#! /usr/bin/perl

# Copyright (C) 2015-2020 SUSE LLC
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

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Output;
use Test::Warnings;
use OpenQA::App;
use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;
use OpenQA::Client;
use Mojo::IOLoop;
use Mojo::File 'path';
use Digest::MD5;
use OpenQA::Events;

require OpenQA::Schema::Result::Jobs;

OpenQA::Test::Case->new->init_data;

my $chunk_size = 10000000;

OpenQA::Events->singleton->on('chunk_upload.end' => sub { Devel::Cover::report() if Devel::Cover->can('report'); });

sub calculate_file_md5($) {
    my ($file) = @_;
    my $c      = path($file)->slurp;
    my $md5    = Digest::MD5->new;
    $md5->add($c);
    return $md5->hexdigest;
}

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema = $t->app->schema;
my $jobs   = $schema->resultset('Jobs');

$jobs->find(99963)->update({assigned_worker_id => 1});

# INITIAL JOB LIST (from fixtures)
# 99981 cancelled  no clone
# 99963 running    no clone
# 99962 done       clone_id: 99963 (running)
# 99961 running    no clone
# 99947 done       no clone
# 99946 done       no clone
# 99945 done       clone_id: 99946 (also done)
# 99944 done       clone_id: 99945 (also done)
# 99940 done       no clone
# 99939 done       no clone
# 99938 done       no clone
# 99937 done       no clone
# 99936 done       no clone
# 99928 scheduled  no clone
# 99927 scheduled  no clone
# 99926 done       no clone

# First, let's try /jobs and ensure the initial state
$t->get_ok('/api/v1/jobs');
my @jobs       = @{$t->tx->res->json->{jobs}};
my $jobs_count = scalar @jobs;
is($jobs_count, 18);
my %jobs = map { $_->{id} => $_ } @jobs;
is($jobs{99981}->{state},              'cancelled');
is($jobs{99981}->{origin_id},          undef, 'no original job');
is($jobs{99981}->{assigned_worker_id}, undef, 'no worker assigned');
is($jobs{99963}->{state},              'running');
is($jobs{99963}->{assigned_worker_id}, 1, 'worker 1 assigned');
is($jobs{99927}->{state},              'scheduled');
is($jobs{99946}->{clone_id},           undef, 'no clone');
is($jobs{99946}->{origin_id},          99945, 'original job');
is($jobs{99963}->{clone_id},           undef, 'no clone');
is($jobs{99926}->{result},             INCOMPLETE, 'job is incomplete');
is($jobs{99926}->{reason},             'just a test', 'job has incomplete reason');

# That means that only 9 are current and only 10 are relevant
$t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$t->tx->res->json->{jobs}}), 15);
$t->get_ok('/api/v1/jobs' => form => {scope => 'relevant'});
is(scalar(@{$t->tx->res->json->{jobs}}), 16);

# check limit quantity
$t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 20000})->status_is(400)
  ->json_is({error => 'limit exceeds maximum', error_status => 400});
$t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 'foo'})->status_is(400)
  ->json_is({error => 'limit is not an unsigned number', error_status => 400});
$t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 5})->status_is(200);
is(scalar(@{$t->tx->res->json->{jobs}}), 5);

# check job group
$t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'opensuse test'});
is(scalar(@{$t->tx->res->json->{jobs}}), 1);
is($t->tx->res->json->{jobs}->[0]->{id}, 99961);
$t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'foo bar'});
is(scalar(@{$t->tx->res->json->{jobs}}), 0);

# Test restricting list

# query for existing jobs by iso
$t->get_ok('/api/v1/jobs?iso=openSUSE-13.1-DVD-i586-Build0091-Media.iso');
is(scalar(@{$t->tx->res->json->{jobs}}), 6);

# query for existing jobs by build
$t->get_ok('/api/v1/jobs?build=0091');
is(scalar(@{$t->tx->res->json->{jobs}}), 11);

# query for existing jobs by hdd_1
$t->get_ok('/api/v1/jobs?hdd_1=openSUSE-13.1-x86_64.hda');
is(scalar(@{$t->tx->res->json->{jobs}}), 3);

# query for some combinations with test
$t->get_ok('/api/v1/jobs?test=kde');
is(scalar(@{$t->tx->res->json->{jobs}}), 6);
$t->get_ok('/api/v1/jobs?test=kde&result=passed');
is(scalar(@{$t->tx->res->json->{jobs}}), 1);
$t->get_ok('/api/v1/jobs?test=kde&result=softfailed');
is(scalar(@{$t->tx->res->json->{jobs}}), 2);
$t->get_ok('/api/v1/jobs?test=kde&result=softfailed&machine=64bit');
is(scalar(@{$t->tx->res->json->{jobs}}), 1);
$t->get_ok('/api/v1/jobs?test=kde&result=passed&machine=64bit');
is(scalar(@{$t->tx->res->json->{jobs}}), 0);

# test limiting options
$t->get_ok('/api/v1/jobs?limit=5');
is(scalar(@{$t->tx->res->json->{jobs}}), 5);
$t->get_ok('/api/v1/jobs?limit=1');
is(scalar(@{$t->tx->res->json->{jobs}}), 1);
is($t->tx->res->json->{jobs}->[0]->{id}, 99981);
$t->get_ok('/api/v1/jobs?limit=1&page=2');
is(scalar(@{$t->tx->res->json->{jobs}}), 1);
is($t->tx->res->json->{jobs}->[0]->{id}, 99963);
$t->get_ok('/api/v1/jobs?before=99928');
is(scalar(@{$t->tx->res->json->{jobs}}), 4);
$t->get_ok('/api/v1/jobs?after=99945');
is(scalar(@{$t->tx->res->json->{jobs}}), 6);

# test multiple arg forms
$t->get_ok('/api/v1/jobs?ids=99981,99963,99926');
is(scalar(@{$t->tx->res->json->{jobs}}), 3);
$t->get_ok('/api/v1/jobs?ids=99981&ids=99963&ids=99926');
is(scalar(@{$t->tx->res->json->{jobs}}), 3);

subtest 'job overview' => sub {
    my $query = Mojo::URL->new('/api/v1/jobs/overview');

    # overview for latest build in group 1001
    $query->query(
        distri  => 'opensuse',
        version => 'Factory',
        groupid => '1001',
    );
    $t->get_ok($query->path_query)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                id   => 99940,
                name => 'opensuse-Factory-DVD-x86_64-Build0048@0815-doc@64bit',
            }
        ],
        'latest build present'
    );

    # overview for build 0048
    $query->query(build => '0048',);
    $t->get_ok($query->path_query)->status_is(200);
    is_deeply(
        $t->tx->res->json,
        [
            {
                id   => 99939,
                name => 'opensuse-Factory-DVD-x86_64-Build0048-kde@64bit',
            },
            {
                id   => 99938,
                name => 'opensuse-Factory-DVD-x86_64-Build0048-doc@64bit',
            },
            {
                id   => 99936,
                name => 'opensuse-Factory-DVD-x86_64-Build0048-kde@64bit-uefi',
            },
        ],
        'latest build present'
    );
};

# Test /jobs/restart
$t->post_ok('/api/v1/jobs/restart', form => {jobs => [99981, 99963, 99962, 99946, 99945, 99927, 99939]})
  ->status_is(200);

$t->get_ok('/api/v1/jobs');
my @new_jobs = @{$t->tx->res->json->{jobs}};
is(scalar(@new_jobs), $jobs_count + 5, '5 new jobs - for 81, 63, 46, 39 and 61 from dependency');
my %new_jobs = map { $_->{id} => $_ } @new_jobs;
is($new_jobs{99981}->{state}, 'cancelled');
is($new_jobs{99927}->{state}, 'scheduled');
like($new_jobs{99939}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99946}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99963}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99981}->{clone_id}, qr/\d/, 'job cloned');
my $cloned = $new_jobs{$new_jobs{99939}->{clone_id}};

# The number of current jobs doesn't change
$t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$t->tx->res->json->{jobs}}), 15, 'job count stay the same');

# Test /jobs/X/restart and /jobs/X
$t->get_ok('/api/v1/jobs/99926')->status_is(200);
ok(!$t->tx->res->json->{job}->{clone_id}, 'job is not a clone');
$t->post_ok('/api/v1/jobs/99926/restart')->status_is(200);
$t->get_ok('/api/v1/jobs/99926')->status_is(200);
like($t->tx->res->json->{job}->{clone_id}, qr/\d/, 'job cloned');

use File::Temp;
my ($fh, $filename) = File::Temp::tempfile(UNLINK => 1);
seek($fh, 20 * 1024 * 1024, 0);    # create 200MB quick
syswrite($fh, "X");
close($fh);

my $rp = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/video.ogv";
unlink($rp);                       # make sure previous tests don't fool us
$t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'video.ogv'}})
  ->status_is(200);

ok(-e $rp, 'video exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");

$rp = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/y2logs.tar.bz2";
$t->post_ok(
    '/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'y2logs.tar.bz2'}, ulog => 1})
  ->status_is(200);
$t->content_is('OK');
ok(-e $rp, 'logs exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");


$rp = "t/data/openqa/share/factory/hdd/hdd_image.qcow2";
unlink($rp);
$t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $filename, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(500);
my $error = $t->tx->res->json->{error};
like($error, qr/Failed receiving chunk/);

#Get chunks!
use OpenQA::File;
use Mojo::File 'tempfile';
my $chunkdir = 't/data/openqa/share/factory/tmp/public/hdd_image.qcow2.CHUNKS/';

path($chunkdir)->remove_tree;
my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);

$pieces->each(
    sub {
        $_->prepare;
        my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
        $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
              {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(200);
        my $error  = $t->tx->res->json->{error};
        my $status = $t->tx->res->json->{status};

        ok !$error or die diag explain $t->tx->res->json;
        is $status, 'ok';
        ok(-d $chunkdir, 'Chunk directory exists') unless $_->is_last;
        #  ok((-e path($chunkdir, $_->index)), 'Chunk is there') unless $_->is_last;

        $_->content(\undef);
    });

ok(!-d $chunkdir, 'Chunk directory should not exist anymore');

ok(-e $rp, 'Asset exists after upload');

$t->get_ok('/api/v1/assets/hdd/hdd_image.qcow2')->status_is(200);
is($t->tx->res->json->{name}, 'hdd_image.qcow2');

$pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);

# Test failure - if chunks are broken
$pieces->each(
    sub {
        $_->prepare;
        $_->content(int(rand(99999)));
        my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
        $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
              {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});
        my $error  = $t->tx->res->json->{error};
        my $status = $t->tx->res->json->{status};

        #  like $error, qr/Checksum mismatch expected/ if $_->is_last;
        like $error, qr/Can't verify written data from chunk/ unless $_->is_last();
        ok(!-d $chunkdir,                           'Chunk directory does not exists') if $_->is_last;
        ok((-e path($chunkdir, 'hdd_image.qcow2')), 'Chunk is there') unless $_->is_last;
    });

ok(!-d $chunkdir, 'Chunk directory does not exists - upload failed');
$t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(404);
$t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(404);

$pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);

# Simulate an error - only the last chunk will be cksummed with an offending content
# That will fail during total cksum calculation
$pieces->each(
    sub {
        $_->content(int(rand(99999))) if $_->is_last;
        $_->prepare;
        my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
        $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
              {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});
        my $error  = $t->tx->res->json->{error};
        my $status = $t->tx->res->json->{status};
        ok !$error unless $_->is_last();
        like $error, qr/Checksum mismatch expected/ if $_->is_last;
        ok(!-d $chunkdir, 'Chunk directory does not exists') if $_->is_last;
    });

ok(!-d $chunkdir, 'Chunk directory does not exists - upload failed');
$t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(404);
$t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(404);


$pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);

my $first_chunk = $pieces->first;
$first_chunk->prepare;

my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
$t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});

is $t->tx->res->json->{status}, 'ok';
ok(-d $chunkdir, 'Chunk directory exists');
#ok((-e path($chunkdir, $first_chunk->index)), 'Chunk is there') or die;

# Simulate worker failed upload
$t->post_ok(
    '/api/v1/jobs/99963/upload_state' => form => {filename => 'hdd_image.qcow2', scope => 'public', state => 'fail'});
ok(!-d $chunkdir,                              'Chunk directory was removed') or die;
ok((!-e path($chunkdir, $first_chunk->index)), 'Chunk was removed')           or die;

# Test for private assets
$chunkdir = 't/data/openqa/share/factory/tmp/private/00099963-hdd_image.qcow2.CHUNKS/';
path($chunkdir)->remove_tree;

$pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);

$first_chunk = $pieces->first;
$first_chunk->prepare;

$chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
$t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'private'});

is $t->tx->res->json->{status}, 'ok';
ok(-d $chunkdir, 'Chunk directory exists');
#ok((-e path($chunkdir, $first_chunk->index)), 'Chunk is there') or die;

# Simulate worker failed upload
$t->post_ok(
    '/api/v1/jobs/99963/upload_state' => form => {
        filename => 'hdd_image.qcow2',
        scope    => 'private',
        state    => 'fail'
    });

ok(!-d $chunkdir,                              'Chunk directory was removed') or die;
ok((!-e path($chunkdir, $first_chunk->index)), 'Chunk was removed')           or die;

$t->get_ok('/api/v1/assets/hdd/00099963-hdd_image.qcow2')->status_is(404);

$pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
ok(!-d $chunkdir, 'Chunk directory empty');
my $sum = OpenQA::File->file_digest($filename);
is $sum, $pieces->first->total_cksum or die 'Computed cksum is not same';
$pieces->each(
    sub {
        $_->prepare;
        my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
        $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
              {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'private'})->status_is(200);
        my $error  = $t->tx->res->json->{error};
        my $status = $t->tx->res->json->{status};

        ok !$error or die diag explain $t->tx->res->json;
        is $status, 'ok';
        ok(-d $chunkdir, 'Chunk directory exists') unless $_->is_last;
        #    ok((-e path($chunkdir, $_->index)), 'Chunk is there') unless $_->is_last;
    });

ok(!-d $chunkdir, 'Chunk directory should not exist anymore');
ok(-e $rp,        'Asset exists after upload');

$t->get_ok('/api/v1/assets/hdd/00099963-hdd_image.qcow2')->status_is(200);
is($t->tx->res->json->{name}, '00099963-hdd_image.qcow2');


# Test for private assets
$chunkdir = 't/data/openqa/share/factory/tmp/00099963-new_ltp_result_array.json.CHUNKS/';
path($chunkdir)->remove_tree;

# Try to send very small-sized data
$pieces = OpenQA::File->new(file => Mojo::File->new('t/data/new_ltp_result_array.json'))->split($chunk_size);

is $pieces->size(), 1 or die 'Size should be 1!';
$first_chunk = $pieces->first;
$first_chunk->prepare;

$chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
$t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $chunk_asset, filename => 'new_ltp_result_array.json'}, asset => 'other'});

is $t->tx->res->json->{status}, 'ok';
ok(!-d $chunkdir, 'Chunk directory doesnt exists');
$t->get_ok('/api/v1/assets/other/00099963-new_ltp_result_array.json')->status_is(200);


# /api/v1/jobs supports filtering by state, result
my $query = Mojo::URL->new('/api/v1/jobs');
for my $state (OpenQA::Schema::Result::Jobs->STATES) {
    $query->query(state => $state);
    $t->get_ok($query->path_query)->status_is(200);
    my $res = $t->tx->res->json;
    for my $job (@{$res->{jobs}}) {
        is($job->{state}, $state);
    }
}

for my $result (OpenQA::Schema::Result::Jobs->RESULTS) {
    $query->query(result => $result);
    $t->get_ok($query->path_query)->status_is(200);
    my $res = $t->tx->res->json;
    for my $job (@{$res->{jobs}}) {
        is($job->{result}, $result);
    }
}

for my $result ('failed,none', 'passed,none', 'failed,passed') {
    $query->query(result => $result);
    $t->get_ok($query->path_query)->status_is(200);
    my $res  = $t->tx->res->json;
    my $cond = $result =~ s/,/|/r;
    for my $job (@{$res->{jobs}}) {
        like($job->{result}, qr/$cond/);
    }
}

$query->query(result => 'nonexistent_result');
$t->get_ok($query->path_query)->status_is(200);
my $res = $t->tx->res->json;
ok(!@{$res->{jobs}}, 'no result for nonexising result');

$query->query(state => 'nonexistent_state');
$t->get_ok($query->path_query)->status_is(200);
$res = $t->tx->res->json;
ok(!@{$res->{jobs}}, 'no result for nonexising state');

subtest 'Check job status and output' => sub {
    $t->get_ok('/api/v1/jobs');
    @new_jobs = @{$t->tx->res->json->{jobs}};
    my $running_job_id;

    local $ENV{MOJO_LOG_LEVEL} = 'debug';
    local $ENV{OPENQA_LOGFILE};
    local $ENV{OPENQA_WORKER_LOGDIR};
    OpenQA::App->singleton->log(Mojo::Log->new(handle => \*STDOUT));

    for my $job (@new_jobs) {
        my $worker_id = $job->{assigned_worker_id};
        my $json      = {};
        if ($worker_id) {
            $json->{status} = {worker_id => $worker_id};
            $running_job_id = $job->{id};
        }

        combined_like(
            sub {
                $t->post_ok("/api/v1/jobs/$job->{id}/status", json => $json);
            },
            $job->{id} == 99963 ? qr// : qr/Got status update for job .*? but does not contain a worker id!/,
            "status for $job->{id}"
        );
        $t->status_is($job->{id} == 99963 ? 200 : 400);
        $worker_id = 0;
    }

    # bogus job ID
    combined_like(
        sub {
            $t->post_ok("/api/v1/jobs/9999999/status", json => {})->status_is(400);
        },
        qr/Got status update for non-existing job/,
        'reject status update for non-existing job'
    );

    # bogus worker ID
    combined_like(
        sub {
            $t->post_ok("/api/v1/jobs/$running_job_id/status", json => {status => {worker_id => 999999}})
              ->status_is(400);
        },
        qr/Got status update for job .* with unexpected worker ID 999999 \(expected 1, job is running\)/,
        'reject status update for job that does not belong to worker'
    );

    # expected not update anymore
    my $job = $jobs->find($running_job_id);
    $schema->txn_begin;
    $job->worker->update({job_id => undef});
    $job->update({state => OpenQA::Jobs::Constants::DONE, result => OpenQA::Jobs::Constants::INCOMPLETE});
    combined_like(
        sub {
            $t->post_ok("/api/v1/jobs/$running_job_id/status", json => {status => {worker_id => 999999}})
              ->status_is(400);
        },
qr/Got status update for job .* with unexpected worker ID 999999 \(expected no updates anymore, job is done with result incomplete\)/,
        'reject status update for job that is already considered incomplete'
    );
    $schema->txn_rollback;
};

# Test /jobs/cancel
# TODO: cancelling jobs via API in tests doesn't work for some reason
#
# $t->post_ok('/api/v1/jobs/cancel?BUILD=0091')->status_is(200);
#
# $t->get_ok('/api/v1/jobs');
# @new_jobs = @{$t->tx->res->json->{jobs}};
#
# foreach my $job (@new_jobs) {
#     if ($job->{settings}->{BUILD} eq '0091') {
#         is($job->{state}, 'cancelled', "job $job->{id} was cancelled");
#     }
# }
#
# is($cloned->{state}, 'scheduled');

# helper to find a build in the JSON results
sub find_build {
    my ($results, $build_id) = @_;

    for my $build_res (@{$results->{build_results}}) {
        OpenQA::Utils::log_debug('key: ' . $build_res->{key});
        if ($build_res->{key} eq $build_id) {
            return $build_res;
        }
    }
}

subtest 'json representation of group overview (actually not part of the API)' => sub {
    $t->get_ok('/group_overview/1001.json')->status_is(200);
    my $json       = $t->tx->res->json;
    my $group_info = $json->{group};
    ok($group_info, 'group info present');
    is($group_info->{id},   1001,       'group ID');
    is($group_info->{name}, 'opensuse', 'group name');

    my $b48 = find_build($json, 'Factory-0048');
    delete $b48->{oldest};
    is_deeply(
        $b48,
        {
            reviewed        => '',
            softfailed      => 1,
            failed          => 1,
            labeled         => 0,
            all_passed      => '',
            total           => 3,
            passed          => 0,
            skipped         => 0,
            distris         => {'opensuse' => 1},
            unfinished      => 1,
            version         => 'Factory',
            escaped_version => 'Factory',
            build           => '0048',
            escaped_build   => '0048',
            escaped_id      => 'Factory-0048',
            key             => 'Factory-0048',
        },
        'Build 0048 exported'
    );
};

$t->get_ok('/dashboard_build_results.json?limit_builds=10')->status_is(200);
my $ret = $t->tx->res->json;
is(@{$ret->{results}}, 2);
my $g1 = (shift @{$ret->{results}});
is($g1->{group}->{name}, 'opensuse', 'First group is opensuse');
my $b1 = find_build($g1, '13.1-0092');
delete $b1->{oldest};
is_deeply(
    $b1,
    {
        passed          => 1,
        version         => '13.1',
        distris         => {'opensuse' => 1},
        labeled         => 0,
        total           => 1,
        failed          => 0,
        unfinished      => 0,
        skipped         => 0,
        reviewed        => '1',
        softfailed      => 0,
        all_passed      => 1,
        version         => '13.1',
        escaped_version => '13_1',
        build           => '0092',
        escaped_build   => '0092',
        escaped_id      => '13_1-0092',
        key             => '13.1-0092',
    },
    'Build 92 of opensuse'
);

my %jobs_post_params = (
    iso     => 'openSUSE-%VERSION%-%FLAVOR%-x86_64-Current.iso',
    DISTRI  => 'opensuse',
    VERSION => 'Tumbleweed',
    FLAVOR  => 'DVD',
    TEST    => 'awesome',
    MACHINE => '64bit',
    BUILD   => '1234',
    _GROUP  => 'opensuse',
);

subtest 'WORKER_CLASS correctly assigned when posting job' => sub {
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    is($jobs->find($t->tx->res->json->{id})->settings_hash->{WORKER_CLASS},
        'qemu_x86_64', 'default WORKER_CLASS assigned (with arch fallback)');

    $jobs_post_params{ARCH} = 'aarch64';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    is($jobs->find($t->tx->res->json->{id})->settings_hash->{WORKER_CLASS},
        'qemu_aarch64', 'default WORKER_CLASS assigned');

    $jobs_post_params{WORKER_CLASS} = 'svirt';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    is($jobs->find($t->tx->res->json->{id})->settings_hash->{WORKER_CLASS}, 'svirt', 'specified WORKER_CLASS assigned');
};

subtest 'default priority correctly assigned when posting job' => sub {
    # post new job and check default priority
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group',    'opensuse');
    $t->json_is('/job/priority', 50);

    # post new job in job group with customized default priority
    $t->app->schema->resultset('JobGroups')->find({name => 'opensuse test'})->update({default_priority => 42});
    $jobs_post_params{_GROUP} = 'opensuse test';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group',    'opensuse test');
    $t->json_is('/job/priority', 42);
};

subtest 'specifying group by ID' => sub {
    delete $jobs_post_params{_GROUP};
    $jobs_post_params{_GROUP_ID} = 1002;
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group',    'opensuse test');
    $t->json_is('/job/priority', 42);
};

subtest 'TEST is only mandatory parameter' => sub {
    $t->post_ok('/api/v1/jobs', form => {TEST => 'pretty_empty'})->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/settings/TEST'    => 'pretty_empty');
    $t->json_is('/job/settings/MACHINE' => undef, 'machine was not set and is therefore undef');
    $t->json_is('/job/settings/DISTRI'  => undef);
};

subtest 'Job with JOB_TEMPLATE_NAME' => sub {
    $jobs_post_params{JOB_TEMPLATE_NAME} = 'foo';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200, 'posted job with job template name');
    is(
        $jobs->find($t->tx->res->json->{id})->settings_hash->{NAME},
        '00099995-opensuse-Tumbleweed-DVD-aarch64-Build1234-foo@64bit',
        'job template name reflected in scenario name'
    );
    delete $jobs_post_params{JOB_TEMPLATE_NAME};
};

subtest 'Expand specified Machine, Testsuite, Product variables' => sub {
    my $products = $t->app->schema->resultset('Products');
    $products->create(
        {
            version     => '15-SP1',
            name        => '',
            distri      => 'sle',
            arch        => 'x86_64',
            description => '',
            flavor      => 'Installer-DVD',
            settings    => [
                {key => 'BUILD_SDK',           value => '%BUILD%'},
                {key => 'BETA',                value => '1'},
                {key => 'ISO_MAXSIZE',         value => '4700372992'},
                {key => 'BUILD_HA',            value => '%BUILD%'},
                {key => 'BUILD_SES',           value => '%BUILD%'},
                {key => 'SHUTDOWN_NEEDS_AUTH', value => '1'},
                {
                    key   => 'HDD_1',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
                {
                    key   => 'PUBLISH_HDD_1',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
                {
                    key   => 'ANOTHER_JOB',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
            ],
        });
    $t->app->schema->resultset('TestSuites')->create(
        {
            name        => 'autoupgrade',
            description => '',
            settings    => [
                {key => 'DESKTOP',     value => 'gnome'},
                {key => 'INSTALLONLY', value => '1'},
                {key => 'MACHINE',     value => '64bit'},
                {key => 'PATCH',       value => '1'},
                {key => 'UPGRADE',     value => '1'},
            ],
        });

    my %new_jobs_post_params = (
        iso     => 'SLE-%VERSION%-%FLAVOR%-%MACHINE%-Build%BUILD%-Media1.iso',
        DISTRI  => 'sle',
        VERSION => '15-SP1',
        FLAVOR  => 'Installer-DVD',
        ARCH    => 'x86_64',
        TEST    => 'autoupgrade',
        MACHINE => '64bit',
        BUILD   => '1234',
        _GROUP  => 'opensuse',
    );

    $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(200);
    my $result = $jobs->find($t->tx->res->json->{id})->settings_hash;
    delete $result->{NAME};
    is_deeply(
        $result,
        {
            'QEMUCPU'             => 'qemu64',
            'VERSION'             => '15-SP1',
            'DISTRI'              => 'sle',
            'MACHINE'             => '64bit',
            'FLAVOR'              => 'Installer-DVD',
            'ARCH'                => 'x86_64',
            'BUILD'               => '1234',
            'ISO_MAXSIZE'         => '4700372992',
            'INSTALLONLY'         => 1,
            'WORKER_CLASS'        => 'qemu_x86_64',
            'DESKTOP'             => 'gnome',
            'ISO'                 => 'SLE-15-SP1-Installer-DVD-64bit-Build1234-Media1.iso',
            'BUILD_HA'            => '1234',
            'TEST'                => 'autoupgrade',
            'BETA'                => 1,
            'BUILD_SES'           => '1234',
            'BUILD_SDK'           => '1234',
            'SHUTDOWN_NEEDS_AUTH' => 1,
            'PATCH'               => 1,
            'UPGRADE'             => 1,
            'PUBLISH_HDD_1'       => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
            'ANOTHER_JOB'         => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
            'HDD_1'               => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
        },
        'Job post method expand specified MACHINE, PRODUCT, TESTSUITE variable',
    );
};

subtest 'circular reference settings' => sub {
    my $products = $t->app->schema->resultset('Products');
    $products->create(
        {
            version     => '12-SP5',
            name        => '',
            distri      => 'sle',
            arch        => 'x86_64',
            description => '',
            flavor      => 'Installer-DVD',
            settings    => [
                {key => 'BUILD_SDK',           value => '%BUILD_HA%'},
                {key => 'BETA',                value => '1'},
                {key => 'ISO_MAXSIZE',         value => '4700372992'},
                {key => 'BUILD_HA',            value => '%BUILD%'},
                {key => 'BUILD_SES',           value => '%BUILD%'},
                {key => 'SHUTDOWN_NEEDS_AUTH', value => '1'},
                {
                    key   => 'PUBLISH_HDD_1',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
            ],
        });
    $t->app->schema->resultset('TestSuites')->create(
        {
            name        => 'circular',
            description => '',
            settings    => [
                {key => 'DESKTOP',     value => 'gnome'},
                {key => 'INSTALLONLY', value => '1'},
                {key => 'MACHINE',     value => '64bit'},
                {key => 'PATCH',       value => '1'},
                {key => 'UPGRADE',     value => '1'},
            ],
        });

    my %new_jobs_post_params = (
        iso     => 'SLE-%VERSION%-%FLAVOR%-%MACHINE%-Build%BUILD%-Media1.iso',
        DISTRI  => 'sle',
        VERSION => '12-SP5',
        FLAVOR  => 'Installer-DVD',
        ARCH    => 'x86_64',
        TEST    => 'circular',
        MACHINE => '64bit',
        BUILD   => '%BUILD_HA%',
        _GROUP  => 'opensuse',
    );

    $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(400);
    like(
        $t->tx->res->json->{error},
        qr/The key (\w+) contains a circular reference, its value is %\w+%/,
        'circular reference exit successfully'
    );
};


subtest 'error on insufficient params' => sub {
    $t->post_ok('/api/v1/jobs', form => {})->status_is(400);
};

subtest 'job details' => sub {
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/testresults' => undef, 'Test details are not present');
    $t->json_hasnt('/job/logs/0' => undef, 'Test result logs are empty');

    $t->get_ok('/api/v1/jobs/99963/details')->status_is(200);
    $t->json_has('/job/testresults/0', 'Test details are there');
    $t->json_is('/job/assets/hdd/0',           => 'hdd_image.qcow2', 'Job has hdd_image.qcow2 as asset');
    $t->json_is('/job/testresults/0/category', => 'installation',    'Job category is "installation"');

    $t->get_ok('/api/v1/jobs/99946/details')->status_is(200);
    $t->json_has('/job/testresults/0', 'Test details are there');
    $t->json_is('/job/assets/hdd/0', => 'openSUSE-13.1-x86_64.hda', 'Job has openSUSE-13.1-x86_64.hda as asset');
    $t->json_is('/job/testresults/0/category', => 'installation', 'Job category is "installation"');

    $t->json_is('/job/testresults/5/name', 'logpackages', 'logpackages test is present');
    $t->json_like('/job/testresults/5/details/8/text_data', qr/fate/, 'logpackages has fate');

    $t->get_ok('/api/v1/jobs/99938/details')->status_is(200);

    $t->json_is('/job/logs/0',  'video.ogv',      'Test result logs are present');
    $t->json_is('/job/ulogs/0', 'y2logs.tar.bz2', 'Test result uploaded logs are present');

};

subtest 'update job and job settings' => sub {
    # check defaults
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group'           => 'opensuse',  'current group');
    $t->json_is('/job/priority'        => 56,          'current prio');
    $t->json_is('/job/settings/ARCH'   => 'x86_64',    'current ARCH');
    $t->json_is('/job/settings/FLAVOR' => 'staging_e', 'current FLAVOR');

    # error cases
    $t->put_ok('/api/v1/jobs/3134', json => {group_id => 1002})->status_is(404);
    $t->json_is('/error' => 'Job does not exist', 'error when job id is invalid');
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1234})->status_is(404);
    $t->json_is('/error' => 'Group does not exist', 'error when group id is invalid');
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1002, status => 1})->status_is(400);
    $t->json_is('/error' => 'Column status can not be set', 'error when invalid/not accessible column specified');

    # set columns of job table
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1002, priority => 53})->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group'            => 'opensuse test', 'group changed');
    $t->json_is('/job/priority'         => 53,              'priority change');
    $t->json_is('/job/settings/ARCH'    => 'x86_64',        'settings in job table not altered');
    $t->json_is('/job/settings/DESKTOP' => 'minimalx',      'settings in job settings table not altered');

    # set also job settings
    $t->put_ok(
        '/api/v1/jobs/99926',
        json => {
            priority => 50,
            settings => {
                TEST         => 'minimalx',
                ARCH         => 'i686',
                DESKTOP      => 'kde',
                NEW_KEY      => 'new value',
                WORKER_CLASS => ':MiB:Promised_Land',
            },
        })->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group'            => 'opensuse test', 'group remained the same');
    $t->json_is('/job/priority'         => 50,              'priority change');
    $t->json_is('/job/settings/ARCH'    => 'i686',          'ARCH changed');
    $t->json_is('/job/settings/DESKTOP' => 'kde',           'DESKTOP changed');
    $t->json_is('/job/settings/NEW_KEY' => 'new value',     'NEW_KEY created');
    $t->json_is('/job/settings/FLAVOR'  => undef,           'FLAVOR removed');

    $t->put_ok('/api/v1/jobs/99926', json => {group_id => undef})->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group' => undef, 'group removed');


    # set machine
    $t->put_ok(
        '/api/v1/jobs/99926',
        json => {
            settings => {
                MACHINE      => '64bit',
                WORKER_CLASS => ':UFP:NCC1701F',
            }})->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is(
        '/job/settings' => {
            NAME         => '00099926-@64bit',
            MACHINE      => '64bit',
            WORKER_CLASS => ':UFP:NCC1701F',
        },
        'also name and worker class updated, all other settings cleaned'
    );
};

subtest 'filter by worker_class' => sub {

    $query->query(worker_class => ':MiB:');
    $t->get_ok($query->path_query)->status_is(200);
    my $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'Worker class does not exist');

    $query->query(worker_class => '::');
    $t->get_ok($query->path_query)->status_is(200);
    $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'Wrong worker class provides zero results');

    $query->query(worker_class => ':UFP:');
    $t->get_ok($query->path_query)->status_is(200);
    $res = $t->tx->res->json;
    ok(@{$res->{jobs}} eq 1, 'Known worker class group exists, and returns one job');

    $t->json_is('/jobs/0/settings/WORKER_CLASS' => ':UFP:NCC1701F', 'Correct worker class');

};

subtest 'Parse extra tests results - LTP' => sub {
    use Mojo::File 'path';
    use OpenQA::Parser 'parser';
    my $fname  = 'new_ltp_result_array.json';
    my $junit  = "t/data/$fname";
    my $parser = parser('LTP');
    $parser->include_results(1);
    $parser->load($junit);
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "JUnit",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('FAILED'), 'request FAILED' or die diag explain $t->tx->res->content;

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "foo",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('FAILED'), 'request FAILED';

    ok !-e path($basedir, 'details-LTP_syscalls_accept01.json'), 'detail from LTP was NOT written';

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "LTP",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('OK'), 'request went fine';
    ok !$t->tx->res->content->body_contains('FAILED'), 'request went fine, really';

    ok !-e path($basedir, $fname), 'file was not uploaded';

    # Check now that parser writes what we expect.
    is $parser->tests->size, 4, 'Tests parsed correctly' or die diag $parser->tests->size;

    # Note: if parser fails parsing, tests won't run reliably, that's why we do this
    # At least those two should be there:
    ok -e path($basedir, 'details-LTP_syscalls_accept01.json'), 'detail from LTP was written'
      or die diag explain path($basedir)->list_tree;
    ok -e path($basedir, 'LTP-LTP_syscalls_accept01.txt'), 'LTP was parsed';

    # Now we check what parser expects to have (this have been generated from openQA side)
    $parser->results->each(
        sub {
            my $db_module = $t->app->schema->resultset('Jobs')->find(99963)->modules->find({name => $_->test->name});

            ok -e path($basedir, 'details-' . $_->test->name . '.json'),
              'detail from junit was written for ' . $_->test->name;
            is_deeply $db_module->details->{results}, $_->details;
            is $db_module->name, $_->test->name, 'Modules name are matching';
            is $db_module->script, 'test', 'Modules script are matching';
            is $db_module->category, $_->test->category, 'Modules category are matching';
            is $db_module->result, ($_->result eq 'ok' ? 'passed' : 'failed'), 'Modules can be passed or failed';
            ok -e path($basedir, $_->{text}) for @{$db_module->details->{results}};
        });

    $parser->outputs->each(
        sub {
            ok -e path($basedir, $_->file), 'test result from junit was written for ' . $_->file;
            is path($basedir, $_->file)->slurp, $_->content, 'Content is present for ' . $_->file;
        });
};

subtest 'Parse extra tests results - xunit' => sub {
    use Mojo::File 'path';
    use OpenQA::Parser 'parser';
    my $fname  = 'xunit_format_example.xml';
    my $junit  = "t/data/$fname";
    my $parser = parser('XUnit');
    $parser->include_results(1);
    $parser->load($junit);
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "LTP",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('FAILED'), 'request FAILED';

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "foo",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('FAILED'), 'request FAILED';

    ok !-e path($basedir, 'details-unkn.json'), 'detail from junit was NOT written';

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "XUnit",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('OK'), 'request went fine';
    ok !$t->tx->res->content->body_contains('FAILED'), 'request went fine, really';

    ok !-e path($basedir, $fname), 'file was not uploaded';

    # Check now that parser writes what we expect.
    is $parser->tests->size, 11, 'Tests parsed correctly' or die diag $parser->tests->size;


    # Note: if parser fails parsing, tests won't run reliably, that's why we do this
    # At least those two should be there:
    ok -e path($basedir, 'details-unkn.json'), 'detail from junit was written'
      or die diag explain path($basedir)->list_tree;
    ok -e path($basedir, 'xunit-bacon-1.txt'), 'junit was parsed';

    # Now we check what parser expects to have (this have been generated from openQA side)
    $parser->results->each(
        sub {
            my $db_module = $t->app->schema->resultset('Jobs')->find(99963)->modules->find({name => $_->test->name});

            ok -e path($basedir, 'details-' . $_->test->name . '.json'),
              'detail from junit was written for ' . $_->test->name;
            is_deeply $db_module->details->{results}, $_->details;
            is $db_module->name, $_->test->name, 'Modules name are matching';
            is $db_module->script, 'test', 'Modules script are matching';
            is $db_module->category, $_->test->category, 'Modules category are matching';
            is $db_module->result, ($_->result eq 'ok' ? 'passed' : 'failed'), 'Modules can be passed or failed';
            ok -e path($basedir, $_->{text}) for @{$db_module->details->{results}};
        });


    $parser->outputs->each(
        sub {
            ok -e path($basedir, $_->file), 'test result from junit was written for ' . $_->file;
            is path($basedir, $_->file)->slurp, $_->content, 'Content is present for ' . $_->file;
        });
};

subtest 'Parse extra tests results - junit' => sub {
    use Mojo::File 'path';
    use OpenQA::Parser 'parser';

    my $fname  = 'slenkins_control-junit-results.xml';
    my $junit  = "t/data/$fname";
    my $parser = parser('JUnit');
    $parser->include_results(1);
    $parser->load($junit);
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "foo",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('FAILED'), 'request FAILED';

    ok !-e path($basedir, 'details-1_running_upstream_tests.json'), 'detail from junit was NOT written';

    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {
            file       => {file => $junit, filename => $fname},
            type       => "JUnit",
            extra_test => 1,
            script     => 'test'
        })->status_is(200);

    ok $t->tx->res->content->body_contains('OK'), 'request went fine';
    ok !$t->tx->res->content->body_contains('FAILED'), 'request went fine, really';

    ok !-e path($basedir, $fname), 'file was not uploaded';

    # Check now that parser writes what we expect.
    ok $parser->tests->size > 2, 'Tests parsed correctly';


    # Note: if parser fails parsing, tests won't run reliably, that's why we do this
    # At least those two should be there:
    ok -e path($basedir, 'details-1_running_upstream_tests.json'),   'detail from junit was written';
    ok -e path($basedir, 'tests-systemd-9_post-tests_audits-3.txt'), 'junit was parsed';

    # Now we check what parser expects to have (this have been generated from openQA side)
    $parser->results->each(
        sub {
            my $db_module = $t->app->schema->resultset('Jobs')->find(99963)->modules->find({name => $_->test->name});

            ok -e path($basedir, 'details-' . $_->test->name . '.json'),
              'detail from junit was written for ' . $_->test->name;
            is_deeply $db_module->details->{results}, $_->details;
            is $db_module->name, $_->test->name, 'Modules name are matching';
            is $db_module->script, 'test', 'Modules script are matching';
            is $db_module->category, $_->test->category, 'Modules category are matching';
            is $db_module->result, 'passed', 'Modules result are ok';

            ok -e path($basedir, $_->{text}) for @{$db_module->details->{results}};
        });


    $parser->outputs->each(
        sub {
            ok -e path($basedir, $_->file), 'test result from junit was written for ' . $_->file;
            is path($basedir, $_->file)->slurp, $_->content, 'Content is present for ' . $_->file;
        });
};

subtest 'create job failed when PUBLISH_HDD_1 is invalid' => sub {
    $jobs_post_params{PUBLISH_HDD_1} = 'foo/foo@64bit.qcow2';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(400);
    like($t->tx->res->json->{error}, qr/The PUBLISH_HDD_1 cannot include \/ in value/, 'PUBLISH_HDD_1 is invalid');
};

subtest 'show job modules execution time' => sub {
    my %modules_execution_time = (
        aplay              => '2m 26s',
        consoletest_finish => '2m 44s',
        gnucash            => '3m 7s',
        installer_timezone => '34s'
    );
    $t->get_ok('/api/v1/jobs/99937/details');
    my @testresults     = sort { $a->{name} cmp $b->{name} } @{$t->tx->res->json->{job}->{testresults}};
    my %execution_times = map  { $_->{name} => $_->{execution_time} } @testresults;
    for my $module_name (keys %modules_execution_time) {
        is(
            $execution_times{$module_name},
            $modules_execution_time{$module_name},
            $module_name . ' execution time showed correctly'
        );
    }
    is(scalar(@{$testresults[0]->{details}}), 2,     'the old format json file parsed correctly');
    is($testresults[0]->{execution_time},     undef, 'the old format json file does not include execution_time');
};

subtest 'marking job as done' => sub {
    my $jobs = $schema->resultset('Jobs');
    subtest 'job is currently running' => sub {
        $jobs->find(99961)->update(
            {
                state  => RUNNING,
                result => NONE,
                reason => undef
            });
        $t->post_ok('/api/v1/jobs/99961/set_done?result=incomplete&reason=test')->status_is(200);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        my $json = $t->tx->res->json;
        my $ok   = is($json->{job}->{result}, INCOMPLETE, 'result set');
        $ok = is($json->{job}->{reason}, 'test', 'reason set') && $ok;
        $ok = is($json->{job}->{state},  DONE,   'state set')  && $ok;
        diag explain $json unless $ok;
    };
    subtest 'job is already done with reason, not overriding existing result and reason' => sub {
        $t->post_ok('/api/v1/jobs/99961/set_done?result=passed&reason=foo')->status_is(200);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        my $json = $t->tx->res->json;
        my $ok   = is($json->{job}->{result}, INCOMPLETE, 'result not changed');
        $ok = is($json->{job}->{reason}, 'test', 'reason not changed') && $ok;
        diag explain $json unless $ok;
    };
    subtest 'job is already done without reason, add reason but do not override result' => sub {
        $jobs->find(99961)->update({reason => undef});
        $t->post_ok('/api/v1/jobs/99961/set_done?result=passed&reason=foo')->status_is(200);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        my $json = $t->tx->res->json;
        my $ok   = is($json->{job}->{result}, INCOMPLETE, 'result not changed');
        $ok = is($json->{job}->{reason}, 'foo', 'reason updated') && $ok;
        diag explain $json unless $ok;
    };
    subtest 'job is already done, no parameters specified' => sub {
        $t->post_ok('/api/v1/jobs/99961/set_done')->status_is(200);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        my $json = $t->tx->res->json;
        my $ok   = is($json->{job}->{result}, INCOMPLETE, 'previous result not lost');
        $ok = is($json->{job}->{reason}, 'foo', 'previous reason not lost') && $ok;
        diag explain $json unless $ok;
    };
};

# delete the job with a registered job module
$t->delete_ok('/api/v1/jobs/99937')->status_is(200);
$t->get_ok('/api/v1/jobs/99937')->status_is(404);

done_testing();
