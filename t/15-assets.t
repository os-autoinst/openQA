#!/usr/bin/env perl
# Copyright (c) 2015-2021 SUSE LLC
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

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Path qw(remove_tree);
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::Mojo;
use OpenQA::Jobs::Constants;
use OpenQA::Resource::Jobs 'job_restart';
use OpenQA::WebAPI::Controller::API::V1::Worker;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Test::Utils 'embed_server_for_testing';
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebSockets::Client;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Schema::ResultSet::Assets;
use OpenQA::Utils qw(:DEFAULT assetdir);
use Mojo::File 'path';
use Mojo::Util 'monkey_patch';

# mock worker websocket send and record what was sent
my $mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my $mock_send_called;
my $sent = {};
$mock->redefine(
    ws_send => sub {
        my ($self, $worker) = @_;
        my $hashref = $self->prepare_for_work($worker);
        $hashref->{assigned_worker_id} = $worker->id;
        $sent->{$worker->id}           = {worker => $worker, job => $self};
        $sent->{job}->{$self->id}      = {worker => $worker, job => $self};
        $mock_send_called++;
        return {state => {msg_sent => 1}};
    });

my $schema;
ok($schema = OpenQA::Test::Database->new->create, 'create database')
  || BAIL_OUT('failed to create database');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{global}->{hide_asset_types} = 'repo  foo ';

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client      => OpenQA::WebSockets::Client->singleton,
);

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
my @assets = map { $_->asset->name } $jobA->jobs_assets->all;
is_deeply \@assets, ['whatever.iso'], 'one asset assigned before grabbing (1)' or diag explain \@assets;
my $missing_assets = $jobA->missing_assets;
is_deeply $missing_assets, [], 'all assets present' or diag explain $missing_assets;
my $theasset = $assets[0];
$jobA->set_prio(1);

## test asset is assigned after grab_job
# register worker
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;
my $w;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
like($@, qr/Incompatible websocket API version/, 'Worker no version - incompatible version exception');
$workercaps->{websocket_api_version} = 999999;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
like($@, qr/Incompatible websocket API version/, 'Worker different version - incompatible version exception');
$workercaps->{websocket_api_version} = WEBSOCKET_API_VERSION;
eval { $w = $c->_register($schema, 'host', '1', $workercaps); };
ok(!$@, 'Worker correct version');

my $worker = $schema->resultset('Workers')->find($w);
is($worker->websocket_api_version(), WEBSOCKET_API_VERSION, 'Worker version set correctly');

# grab job
OpenQA::Scheduler::Model::Jobs->singleton->schedule();
my $job = $sent->{$w}->{job}->to_hash;
is($job->{id}, $jobA->id, 'jobA grabbed');
@assets = map { $_->asset->name } $jobA->jobs_assets->all;
is(scalar @assets, 1,         'job still has only one asset assigned after grabbing') or diag explain \@assets;
is($assets[0],     $theasset, 'the assigned asset is the same');

note 'assume worker picked up the job';
$jobA->update({state => SETUP});

# test asset is not assigned to scheduled jobs after duping
my $jobA_id = $jobA->id;
my $res     = job_restart([$jobA_id]);
is(@{$res->{duplicates}}, 1, 'one duplicate');
is(@{$res->{errors}},     0, 'no errors')   or diag explain $res->{errors};
is(@{$res->{warnings}},   0, 'no warnings') or diag explain $res->{warnings};

my $duplicate_id = $res->{duplicates}->[0]->{$jobA_id} or BAIL_OUT "unable to restart $jobA_id";
my $cloneA       = $schema->resultset('Jobs')->find($duplicate_id);
@assets = map { $_->asset->name } $cloneA->jobs_assets->all;
is $assets[0], $theasset, 'clone has the same asset assigned' or diag explain \@assets;

my $jabasename = 'jobasset.raw';
my $janame     = sprintf('%08d-%s', $cloneA->id, $jabasename);
my $japath     = path(assetdir, 'hdd', $janame);
$japath->remove if -e $japath;    # make sure it's gone before creating the job

## test job is assigned all existing assets during creation and the rest during job grab
# create new job depending on one normal and one job asset
$settings{_START_AFTER_JOBS} = [$cloneA->id];
$settings{HDD_1}             = $jabasename;
$settings{TEST}              = 'testB';
my $jobB = $schema->resultset('Jobs')->create_from_settings(\%settings);
@assets = sort map { $_->asset->name } $jobB->jobs_assets->all;
is_deeply \@assets, [$jabasename, $theasset], 'both assets are assigned, jobasset.raw assumed to be public asset'
  or diag explain \@assets;
# set jobA (normally this is done by worker after abort) and cloneA to done
# needed for job grab to fulfill dependencies
$jobA->discard_changes;
is($jobA->done(result => 'passed'),   'passed', 'jobA job set to done');
is($cloneA->done(result => 'passed'), 'passed', 'cloneA job set to done');

# register asset and mark as created by cloneA
path($japath)->spurt('foobar');
my $ja = $schema->resultset('Assets')->create({name => $janame, type => 'hdd'});
$schema->resultset('JobsAssets')->create({job_id => $cloneA->id, asset_id => $ja->id, created_by => 1});

# set jobB to running
$jobB->set_prio(1);
OpenQA::Scheduler::Model::Jobs->singleton->schedule();
$job = $sent->{$w}->{job}->to_hash;
is($job->{id}, $jobB->id, 'jobB grabbed');
@assets = sort map { $_->asset->name } $jobB->jobs_assets->all;
is_deeply \@assets, [$janame, $theasset], 'using correct assets after grabbing' or diag explain \@assets;

## test job is duped when depends on asset created by duping job
# clone cloneA
job_restart([$cloneA->id]);
# check jobB was also duplicated
$jobB->discard_changes();
ok($jobB->clone, 'jobB has a clone after cloning asset creator');

# create a repo asset for the following tests
my $repopath = path(assetdir, 'repo', 'tmprepo');
# ensure no leftovers from previous testing
remove_tree($repopath);
# create some test content to test nested dir size discovery
my $testdir = path($repopath, 'testdir')->make_path;
path($repopath, 'testfile')->spurt('foobar');
path($repopath, 'testfile2')->spurt('meep');
my $repo = $schema->resultset('Assets')->create({name => 'tmprepo', type => 'repo'});

# create a test 'fixed' asset
my $fixed_dir = path(assetdir,   'hdd', 'fixed')->make_path;
my $fixedpath = path($fixed_dir, 'fixed.img');
$fixedpath->spurt('');
my $fixed = $schema->resultset('Assets')->create({name => 'fixed.img', type => 'hdd'});

# test is_fixed
ok(!$ja->is_fixed(),   'ja should not be considered a fixed asset');
ok(!$repo->is_fixed(), 'repo should not be considered a fixed asset');
ok($fixed->is_fixed(), 'fixed should be considered a fixed asset');

# test OpenQA::Utils::locate_asset
# fixed HDD asset
my $expected = path(assetdir, 'hdd', 'fixed', 'fixed.img');
is(locate_asset('hdd', 'fixed.img', mustexist => 1),
    $expected, 'locate_asset should find fixed asset in fixed location');
# relative
$expected = path('hdd', 'fixed', 'fixed.img');
is(locate_asset('hdd', 'fixed.img', mustexist => 1, relative => 1),
    $expected, 'locate_asset should return fixed path as relative');

# transient repo asset
$expected = path(assetdir, 'repo', 'tmprepo');
is(locate_asset('repo', 'tmprepo', mustexist => 1), $expected, 'locate_asset should find tmprepo in expected location');

# non-existent ISO asset
$expected = path(assetdir, 'iso', 'nex.iso');
is(locate_asset('iso', 'nex.iso'), $expected, 'locate_asset 0 should give location for non-existent asset');
ok(!locate_asset('iso', 'nex.iso', mustexist => 1), 'locate_asset 1 should not give location for non-existent asset');

# test ensure_size
is($ja->size,          undef, 'size not immediately set');
is($ja->ensure_size,   6,     'ja asset size should be 6');
is($repo->ensure_size, 10,    'repo asset size should be 10');

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

ok $mock_send_called, 'mocked ws_send method has been called';

subtest 'asset status' => sub {
    my $asset_cache_file = OpenQA::Schema::ResultSet::Assets::status_cache_file;
    note("asset cache file is expected to be created under $asset_cache_file");

    my $gru_mock            = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
    my $limit_assets_active = 1;
    $gru_mock->redefine(
        is_task_active => sub {
            my ($self, $task) = @_;
            return $limit_assets_active if $task eq 'limit_assets';
            fail("is_task_active called for unexpected task $task");    # uncoverable statement
        });

    # ensure cache file does not exist from a previous test run
    unlink($asset_cache_file);

    $t->get_ok('/admin/assets/status?force_refresh=1')
      ->status_is(400, 'viewing assets page without cache file not possible during cleanup')
      ->json_is('/error' => 'Asset cleanup is currently ongoing.');

    $limit_assets_active = 0;
    $t->get_ok('/admin/assets/status')->status_is(200, 'viewing assets possible when cleanup finished');
    my $json = $t->tx->res->json;
    is(ref $json,           'HASH',  'asset status JSON present');
    is(ref $json->{data},   'ARRAY', 'assets array present');
    is(ref $json->{groups}, 'HASH',  'groups hash present');
    ok(-f $asset_cache_file, 'asset cache file has been created');

    $limit_assets_active = 1;
    $t->get_ok('/admin/assets/status?force_refresh=1')
      ->status_is(400, 'viewing assets page with force_refresh not possible during cleanup')
      ->json_is('/error' => 'Asset cleanup is currently ongoing.');
    $t->get_ok('/admin/assets/status')
      ->status_is(200, 'asset status rendered from cache file although cleanup is ongoing');
};


subtest 'check for hidden assets' => sub {
    ok(OpenQA::Schema::Result::Assets::is_type_hidden('repo'), 'repo is considered hidden');
    ok(OpenQA::Schema::Result::Assets::is_type_hidden('foo'),  'foo is considered hidden');
    ok(!OpenQA::Schema::Result::Assets::is_type_hidden('bar'), 'bar is not considered hidden');
};

subtest 'check for missing assets' => sub {
    my $jobs = $schema->resultset('Jobs');
    $settings{ISO_0}            = 'whatever.sha256';    # supposed to exist
    $settings{HDD_1}            = 'not_existent';       # supposed to be missing
    $settings{UEFI_PFLASH_VARS} = 'not_existent';       # supposed to be missing but ignored

    subtest 'one asset is missing' => sub {
        my $job_with_2_assets = $jobs->create_from_settings(\%settings);
        @assets = sort map { $_->asset->name } $job_with_2_assets->jobs_assets;
        is_deeply \@assets, [qw(not_existent whatever.iso whatever.sha256)],
          'two existing and one missing assets assigned'
          or diag explain \@assets;
        is_deeply $job_with_2_assets->missing_assets,
          ['hdd/not_existent'], 'assets are considered missing if at least one is missing'
          or diag explain $job_with_2_assets->missing_assets;
    };
    subtest 'repo assets are ignored' => sub {
        $settings{REPO_0} = delete $settings{HDD_1};
        my $job_with_2_assets = $jobs->create_from_settings(\%settings);
        is_deeply($job_with_2_assets->missing_assets, [], 'repo asset not considered so no asset missing');
    };
    subtest 'empty assets are ignored' => sub {
        delete $settings{REPO_0};
        $settings{ISO} = '';
        my $job_with_2_assets = $jobs->create_from_settings(\%settings);
        is_deeply($job_with_2_assets->missing_assets, [], 'empty asset not considered so no asset missing');
    };
    subtest 'private assets are considered' => sub {
        $settings{HDD_1} = 'disk_from_parent';
        my $parent_job        = $jobs->create_from_settings(\%settings);
        my $job_with_2_assets = $jobs->create_from_settings(\%settings);
        $schema->resultset('JobDependencies')->create(
            {
                child_job_id  => $job_with_2_assets->id,
                parent_job_id => $parent_job->id,
                dependency    => OpenQA::JobDependencies::Constants::CHAINED
            });
        $schema->resultset('Assets')
          ->create({type => 'hdd', name => sprintf("%08d-disk_from_parent", $parent_job->id), size => 0});
        $missing_assets = $job_with_2_assets->missing_assets;
        is_deeply $missing_assets, [], 'private asset created by parent so no asset missing'
          or diag explain $missing_assets;
    };
    subtest 'private assets not reported besides others missing' => sub {
        my $parent_job = $jobs->create_from_settings(\%settings);
        $settings{HDD_2} = 'non_existent';
        my $job_with_2_assets = $jobs->create_from_settings(\%settings);
        $schema->resultset('JobDependencies')->create(
            {
                child_job_id  => $job_with_2_assets->id,
                parent_job_id => $parent_job->id,
                dependency    => OpenQA::JobDependencies::Constants::CHAINED
            });
        $schema->resultset('Assets')
          ->create({type => 'hdd', name => sprintf("%08d-disk_from_parent", $parent_job->id), size => 0});
        @assets         = sort map { $_->asset->name } $job_with_2_assets->jobs_assets->all;
        $missing_assets = $job_with_2_assets->missing_assets;
        is_deeply $missing_assets , ['hdd/non_existent'],
          'private assets correctly detected also when other asset is missing'
          or diag explain $missing_assets;
    };
};

done_testing();
