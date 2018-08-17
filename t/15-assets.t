#! /usr/bin/perl

# Copyright (c) 2015-2018 SUSE LINUX GmbH, Nuernberg, Germany.
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
use FindBin;
use lib "$FindBin::Bin/lib";
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use Data::Dump qw(pp dd);
use File::Path qw(remove_tree);
use File::Spec::Functions 'catfile';
use Test::More;
use Test::Warnings;
use OpenQA::Scheduler::Scheduler 'job_grab';
use OpenQA::Resource::Jobs 'job_restart';
use OpenQA::WebAPI::Controller::API::V1::Worker;
use OpenQA::WebSockets;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Utils;

# create Test DBus bus and service for fake WebSockets call
my $ws = OpenQA::WebSockets->new;

my $schema;
ok($schema = OpenQA::Test::Database->new->create(), 'create database') || BAIL_OUT('failed to create database');
## test asset is not assigned to scheduled jobs after job creation
# create new job
my %settings = (
    DISTRI       => 'Unicorn',
    FLAVOR       => 'pink',
    VERSION      => '42',
    BUILD        => '666',
    ISO          => 'whatever.iso',
    DESKTOP      => 'DESKTOP',
    KVM          => 'KVM',
    ISO_MAXSIZE  => 1,
    MACHINE      => 'RainbowPC',
    ARCH         => 'x86_64',
    TEST         => 'testA',
    WORKER_CLASS => 'testAworker',
);

my $workercaps = {
    cpu_modelname => 'Rainbow CPU',
    cpu_arch      => 'x86_64',
    cpu_opmode    => '32-bit, 64-bit',
    mem_max       => '4096',
    WORKER_CLASS  => 'testAworker',
};

my $jobA   = $schema->resultset('Jobs')->create_from_settings(\%settings);
my @assets = $jobA->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 1, 'one asset assigned before grabbing');
my $theasset = $assets[0];
$jobA->set_prio(1);

## test asset is assigned after grab_job
# register worker
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;
my $w;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
like($@, qr/Incompatible websocket api/, 'Worker no version - incompatible version exception');
$workercaps->{websocket_api_version} = 999999;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
like($@, qr/Incompatible websocket api/, 'Worker different version - incompatible version exception');
$workercaps->{websocket_api_version} = WEBSOCKET_API_VERSION;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
ok(!$@, 'Worker correct version');

my $worker = $schema->resultset('Workers')->find($w);
is($worker->get_websocket_api_version(), WEBSOCKET_API_VERSION, 'Worker version set correctly');

# grab job
my $job = job_grab(workerid => $w, allocate => 1);
is($job->{id}, $jobA->id, 'jobA grabbed');
@assets = $jobA->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 1,         'job still has only one asset assigned after grabbing');
is($assets[0],     $theasset, 'the assigned asset is the same');

# test asset is not assigned to scheduled jobs after duping
my $jobA_id = $jobA->id;
my ($cloneA) = job_restart($jobA_id);
$cloneA = $schema->resultset('Jobs')->find(
    {
        id => $cloneA->{$jobA_id},
    });
@assets = $cloneA->jobs_assets;
@assets = map { $_->asset_id } @assets;
is($assets[0], $theasset, 'clone does have the same asset assigned');

my $janame = sprintf('%08d-%s', $cloneA->id, 'jobasset.raw');
my $japath = catfile($OpenQA::Utils::assetdir, 'hdd', $janame);
# make sure it's gone before creating the job
unlink($japath);

## test job is assigned all existing assets during creation and the rest during job grab
# create new job depending on one normal and one job asset
$settings{_START_AFTER_JOBS} = [$cloneA->id];
$settings{HDD_1}             = 'jobasset.raw';
$settings{TEST}              = 'testB';
my $jobB = $schema->resultset('Jobs')->create_from_settings(\%settings);
@assets = $jobB->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 1, 'one asset assigned before grabbing');
# set jobA (normally this is done by worker after abort) and cloneA to done
# needed for job grab to fulfill dependencies
$jobA->discard_changes;
is($jobA->done(result => 'passed'), 'passed', 'jobA job set to done');
is($cloneA->done(result => 'passed'), 'passed', 'cloneA job set to done');

# register asset and mark as created by cloneA
open(my $fh, '>', $japath);
# give it some content to test ensure_size
print $fh "foobar";
close($fh);
my $ja = $schema->resultset('Assets')->create(
    {
        name => $janame,
        type => 'hdd',
    });
$schema->resultset('JobsAssets')->create(
    {
        job_id     => $cloneA->id,
        asset_id   => $ja->id,
        created_by => 1,
    });

# set jobB to running
$jobB->set_prio(1);
$job = job_grab(workerid => $w, allocate => 1);
is($job->{id}, $jobB->id, 'jobB grabbed');
@assets = $jobB->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 2, 'two assets assigned after grabbing');
is_deeply(\@assets, [$theasset, $ja->id], 'using correct assets');

## test job is duped when depends on asset created by duping job
# clone cloneA
($cloneA) = job_restart($cloneA->id);
# check jobB was also duplicated
$jobB->discard_changes();
ok($jobB->clone, 'jobB has a clone after cloning asset creator');

# create a repo asset for the following tests
my $repopath = catfile($OpenQA::Utils::assetdir, 'repo', 'tmprepo');
# ensure no leftovers from previous testing
remove_tree($repopath);
# create the dir
mkdir($repopath);
# create some test content to test nested dir size discovery
my $testdir = catfile($repopath, 'testdir');
mkdir($testdir);
open($fh, '>', catfile($repopath, 'testfile')) || die "can't open testfile in $repopath";
print $fh 'foobar';
close($fh);
open($fh, '>', catfile($testdir, 'testfile2'));
print $fh 'meep';
close($fh);
my $repo = $schema->resultset('Assets')->create(
    {
        name => 'tmprepo',
        type => 'repo',
    });

# create a test 'fixed' asset
my $fixedpath = catfile($OpenQA::Utils::assetdir, 'hdd', 'fixed', 'fixed.img');
open($fh, '>', $fixedpath);
close($fh);
my $fixed = $schema->resultset('Assets')->create(
    {
        name => 'fixed.img',
        type => 'hdd',
    });

# test is_fixed
ok(!$ja->is_fixed(),   'ja should not be considered a fixed asset');
ok(!$repo->is_fixed(), 'repo should not be considered a fixed asset');
ok($fixed->is_fixed(), 'fixed should be considered a fixed asset');

# test Utils::locate_asset
# fixed HDD asset
my $expected = catfile($OpenQA::Utils::assetdir, 'hdd', 'fixed', 'fixed.img');
is(locate_asset('hdd', 'fixed.img', mustexist => 1),
    $expected, 'locate_asset should find fixed asset in fixed location');
# relative
$expected = catfile('hdd', 'fixed', 'fixed.img');
is(locate_asset('hdd', 'fixed.img', mustexist => 1, relative => 1),
    $expected, 'locate_asset should return fixed path as relative');

# transient repo asset
$expected = catfile($OpenQA::Utils::assetdir, 'repo', 'tmprepo');
is(locate_asset('repo', 'tmprepo', mustexist => 1), $expected, 'locate_asset should find tmprepo in expected location');

# non-existent ISO asset
$expected = catfile($OpenQA::Utils::assetdir, 'iso', 'nex.iso');
is(locate_asset('iso', 'nex.iso'), $expected, 'locate_asset 0 should give location for non-existent asset');
ok(!locate_asset('iso', 'nex.iso', mustexist => 1), 'locate_asset 1 should not give location for non-existent asset');


# test ensure_size
is($ja->ensure_size(),   6,  'ja asset size should be 6');
is($repo->ensure_size(), 10, 'repo asset size should be 10');

# test remove_from_disk
$ja->remove_from_disk();
$fixed->remove_from_disk();
$repo->remove_from_disk();
ok(!-e $japath,    "ja asset should have been removed");
ok(!-e $fixedpath, "fixed asset should have been removed");
ok(!-e $repopath,  "repo asset should have been removed");

# for safety
unlink($japath);
unlink($fixedpath);
remove_tree($repopath);
done_testing();
