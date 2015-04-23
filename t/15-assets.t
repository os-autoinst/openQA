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
use Test::More;
use OpenQA::Scheduler qw/job_create job_grab job_get job_restart job_set_done/;
use OpenQA::Controller::API::V1::Worker;
use OpenQA::Test::Database;

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

my $jobA   = job_create(\%settings);
my @assets = $jobA->jobs_assets;
ok(!@assets, 'no asset assigned before grabbing');
$jobA->set_prio(1);

## test asset is assigned after grab_job
# register worker
my $c = OpenQA::Controller::API::V1::Worker->new;
my $w = $c->_register($schema, 'host', '1', $workercaps);
# grab job
my $job = job_grab(workerid => $w);
is($job->{id}, $jobA->id, 'jobA grabbed');
@assets = $jobA->jobs_assets;
ok(@assets, 'job has asset assigned after grabbing');

# test asset is not assigned to scheduled jobs after duping
my ($cloneA) = job_restart($jobA->id);
$cloneA = $schema->resultset('Jobs')->find(
    {
        id => $cloneA,
    });
@assets = $cloneA->jobs_assets;
ok(!@assets, 'clone does not have asset assigned');

## test job is duped when depends on asset created by duping job
# set jobA (normally this is done by worker after abort) and cloneA to done
ok(job_set_done(jobid => $jobA->id,   result => 'passed'), 'jobA set to done');
ok(job_set_done(jobid => $cloneA->id, result => 'passed'), 'cloneA job set to done');
# register asset as created by cloneA
$schema->resultset('JobsAssets')->create(
    {
        job_id     => $cloneA->id,
        asset_id   => 2,             # took one from fictures
        created_by => 1,
    });
# create new job depending on this asset
$settings{_START_AFTER_JOBS} = [$cloneA->id];
$settings{ISO}               = 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso';    # asset_id 2
$settings{TEST}              = 'testB';
my $jobB = job_create(\%settings);
# set jobB to running
$jobB->set_prio(1);
$job = job_grab(workerid => $w);
is($job->{id},                           $jobB->id, 'jobB grabbed');
is($jobB->jobs_assets->single->asset_id, 2,         'using correct asset');
# clone cloneA
($cloneA) = job_restart($cloneA->id);
# check jobB was also duplicated
$jobB->discard_changes();
ok($jobB->clone, 'jobB has a clone after cloning asset creator');

done_testing();
