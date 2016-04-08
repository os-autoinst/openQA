#!/bin/perl

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
}

use strict;
use warnings;
use Data::Dump qw/pp dd/;
use File::Path qw/remove_tree/;
use Test::More;
use Test::Warnings;
use OpenQA::Scheduler::Scheduler qw/job_grab job_restart job_set_done/;
use OpenQA::WebAPI::Controller::API::V1::Worker;
use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Test::Database;

# create Test DBus bus and service for fake WebSockets call
my $ipc = OpenQA::IPC->ipc('', 1);
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
my $w = $c->_register($schema, 'host', '1', $workercaps);
# grab job
my $job = job_grab(workerid => $w);
is($job->{id}, $jobA->id, 'jobA grabbed');
@assets = $jobA->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 1,         'job still has only one asset assigned after grabbing');
is($assets[0],     $theasset, 'the assigned asset is the same');

# test asset is not assigned to scheduled jobs after duping
my ($cloneA) = job_restart($jobA->id);
$cloneA = $schema->resultset('Jobs')->find(
    {
        id => $cloneA,
    });
@assets = $cloneA->jobs_assets;
@assets = map { $_->asset_id } @assets;
is($assets[0], $theasset, 'clone does have the same asset assigned');

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
ok(job_set_done(jobid => $jobA->id,   result => 'passed'), 'jobA job set to done');
ok(job_set_done(jobid => $cloneA->id, result => 'passed'), 'cloneA job set to done');

# register asset and mark as created by cloneA
my $ja = sprintf('%08d-%s', $cloneA->id, 'jobasset.raw');
open(my $fh, '>', join('/', $OpenQA::Utils::assetdir, 'hdd', $ja));
# give it some content to test ensure_size
print $fh "foobar";
close($fh);
$ja = $schema->resultset('Assets')->create(
    {
        name => $ja,
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
$job = job_grab(workerid => $w);
is($job->{id}, $jobB->id, 'jobB grabbed');
@assets = $jobB->jobs_assets;
@assets = map { $_->asset_id } @assets;
is(scalar @assets, 2, 'two asset assigned after grabbing');
is_deeply(\@assets, [$theasset, $ja->id], 'using correct assets');

## test job is duped when depends on asset created by duping job
# clone cloneA
($cloneA) = job_restart($cloneA->id);
# check jobB was also duplicated
$jobB->discard_changes();
ok($jobB->clone, 'jobB has a clone after cloning asset creator');

# create a repo asset for the following tests
my $repo = join('/', $OpenQA::Utils::assetdir, 'repo', 'testrepo');
# ensure no leftovers from previous testing
remove_tree($repo);
# create the dir
mkdir($repo);
# create some test content to test nested dir size discovery
my $testdir = join('/', $repo, 'testdir');
mkdir($testdir);
open($fh, '>', join('/', $repo, 'testfile'));
print $fh 'foobar';
close($fh);
open($fh, '>', join('/', $testdir, 'testfile2'));
print $fh 'meep';
close($fh);
$repo = $schema->resultset('Assets')->create(
    {
        name => 'testrepo',
        type => 'repo',
    });

# test ensure_size
is($ja->ensure_size(),   6,  'ja asset size should be 6');
is($repo->ensure_size(), 10, 'repo asset size should be 10');

# test remove_from_disk
$ja->remove_from_disk();
$repo->remove_from_disk();
ok(!-e $ja,   "ja asset should have been removed");
ok(!-e $repo, "repo asset should have been removed");

# for safety
unlink($ja->disk_file);
remove_tree($repo->disk_file);
done_testing();
