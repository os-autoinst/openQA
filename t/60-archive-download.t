#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -signatures;
use Test::Most;
use Test::Warnings ':report_warnings';
use Test::Mojo;
use Mojo::File qw(path tempdir);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::MockObject;
use Test::MockModule;

use OpenQA::Test::Case;
use OpenQA::App;
use OpenQA::WebAPI;
use OpenQA::Utils qw(resultdir assetdir);
use OpenQA::Archive;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);

my $tmp = tempdir();
$ENV{OPENQA_BASEDIR} = $tmp->to_string;
$tmp->child('openqa', 'db')->make_path;

my $case = OpenQA::Test::Case->new;
my $schema = $case->init_data;
my $app = OpenQA::WebAPI->new;
OpenQA::App->set_singleton($app);
my $t = Test::Mojo->new($app);

$ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR} = $tmp->child('cache')->to_string;
my $cache_dir = path($ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR});
$cache_dir->make_path;

subtest 'Archive download' => sub {
    my $job = $schema->resultset('Jobs')->create(
        {
            DISTRI => 'archtest',
            VERSION => '1.0',
            FLAVOR => 'test',
            ARCH => 'x86_64',
            TEST => 'testjob',
            state => 'done',
            result => 'passed',
        });
    $job->create_result_dir;
    $job->update({result_dir => $job->result_dir});
    my $res_dir_str = $job->result_dir;
    die 'result_dir is not set' unless $res_dir_str;
    my $res_dir = path($res_dir_str);
    $res_dir->make_path;
    $res_dir->child('details-test.json')->spew('{"test": "data"}');
    $res_dir->child('ulogs')->make_path->child('test.log')->spew('log data');
    my $asset = $schema->resultset('Assets')->create(
        {
            type => 'iso',
            name => 'test.iso',
        });
    $schema->resultset('JobsAssets')->create(
        {
            job_id => $job->id,
            asset_id => $asset->id,
        });
    my $asset_path = path(assetdir(), 'iso', 'test.iso');
    $asset_path->dirname->make_path;
    $asset_path->spew('iso data');

    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(302)->header_like('Location' => qr|/archives/job_|);
    my $archive_url = $t->tx->res->headers->location;
    $t->get_ok('/tests/' . $job->id . '/downloads_ajax')->status_is(200)
      ->element_exists('a[title="Download all test results and assets as a ZIP archive"]');
    $t->get_ok($archive_url)->status_is(200)->content_type_is('application/zip')
      ->header_is('Content-Disposition' => 'attachment; filename=job_' . $job->id . '.zip;');
    my $zip_content = $t->tx->res->body;
    my $zip_file = $tmp->child('downloaded.zip');
    $zip_file->spew($zip_content);
    my $zip = Archive::Zip->new();
    is $zip->read($zip_file->to_string), AZ_OK, 'Zip is valid';
    ok $zip->memberNamed('testresults/details-test.json'), 'Contains test results';
    ok $zip->memberNamed('testresults/ulogs/test.log'), 'Contains ulogs';
    ok $zip->memberNamed('iso/test.iso'), 'Contains assets';
    is $zip->contents('testresults/details-test.json'), '{"test": "data"}', 'Result content is correct';
    is $zip->contents('iso/test.iso'), 'iso data', 'Asset content is correct';
};

subtest 'Archive caching' => sub {
    my $job_id = $schema->resultset('Jobs')->first->id;
    my $cache_file = path($ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR})->child("job_$job_id.zip");
    ok -e $cache_file, 'Archive is cached';
    my $mtime = $cache_file->stat->mtime;
    utime $mtime - 10, $mtime - 10, $cache_file->to_string;
    $mtime = $cache_file->stat->mtime;
    $t->get_ok('/tests/' . $job_id . '/archive')->status_is(302);
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    is $cache_file->stat->mtime, $mtime, 'Cached file was reused';
};

subtest 'Hide "Download All" button when no content' => sub {
    my $job = $schema->resultset('Jobs')->create(
        {
            DISTRI => 'archtest',
            VERSION => '1.0',
            FLAVOR => 'test',
            ARCH => 'x86_64',
            TEST => 'empty_job',
            state => 'done',
            result => 'passed',
        });
    $t->get_ok('/tests/' . $job->id . '/downloads_ajax')->status_is(200)
      ->element_exists_not('a[title="Download all test results and assets as a ZIP archive"]');
};

subtest 'Cache limit calculation' => sub {
    my $orig_config = $app->config->{job_details_archive};
    $app->config->{job_details_archive} = {
        job_details_archive_cache_limit_gb => 1,
        job_details_archive_cache_min_free_percentage => 20,
        job_details_archive_cache_watermark_percentage => 50,
        job_details_archive_cache_dir => $tmp->child('cache_config')->to_string,
    };
    my $orig_env = $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR};
    delete $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR};
    is OpenQA::Archive::archive_cache_dir(), $app->config->{job_details_archive}->{job_details_archive_cache_dir},
      'Cache dir from config';
    is OpenQA::Archive::get_cache_limit(), 1024 * 1024 * 1024, 'Limit in bytes';
    is OpenQA::Archive::get_min_free_percentage(), 20, 'Min free percentage';
    is OpenQA::Archive::get_watermark_percentage(), 50, 'Watermark percentage';
    ok OpenQA::Archive::is_cache_limit_exceeded(2 * 1024 * 1024 * 1024, 100, 1000), 'Limit exceeded by size';
    ok OpenQA::Archive::is_cache_limit_exceeded(100, 10, 100), 'Limit exceeded by free percentage';
    ok !OpenQA::Archive::is_cache_limit_exceeded(100, 30, 100), 'Limit not exceeded';
    delete $app->config->{job_details_archive}->{job_details_archive_cache_dir};
    like OpenQA::Archive::archive_cache_dir(), qr|/cache/archives$|, 'Default cache dir';
    delete $app->config->{job_details_archive};
    is OpenQA::Archive::get_cache_limit(), 5 * 1024 * 1024 * 1024, 'Default limit';
    $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR} = $orig_env;
    $app->config->{job_details_archive} = $orig_config;
};

subtest 'Cache cleanup execution' => sub {
    my $mock_utils = Test::MockModule->new('OpenQA::Utils');
    $mock_utils->mock(check_df => sub { (50, 1000) });
    my $orig_config = $app->config->{job_details_archive};
    $app->config->{job_details_archive} = {
        job_details_archive_cache_limit_gb => 0.000000001,
        job_details_archive_cache_min_free_percentage => 20,
        job_details_archive_cache_watermark_percentage => 1,
    };
    my $now = time();
    for my $i (100 .. 105) {
        my $f = $cache_dir->child("job_$i.zip");
        $f->spew("data $i" . ("x" x 100000));
        utime $now - (200 - $i), $now - (200 - $i), $f->to_string;
    }
    my @initial = $cache_dir->list->grep(sub { $_->basename =~ /^job_\d+\.zip$/ })->each;
    OpenQA::Archive::cleanup_cache();
    my @remaining = $cache_dir->list->grep(sub { $_->basename =~ /^job_\d+\.zip$/ })->each;
    ok scalar(@remaining) < scalar(@initial), 'Some archives were removed during cleanup';
    $app->config->{job_details_archive} = $orig_config;
};

subtest 'Create archive details' => sub {
    my $mock_job = Test::MockObject->new;
    $mock_job->set_always(id => 789);
    $mock_job->set_always(result_dir => $tmp->child('results_dir_789')->to_string);
    $tmp->child('results_dir_789')->make_path;
    my $mock_asset = Test::MockObject->new;
    $mock_asset->set_always(disk_file => $tmp->child('asset_dir_789')->to_string);
    $mock_asset->set_always(name => 'my_asset_dir');
    $mock_asset->set_always(type => 'other');
    $tmp->child('asset_dir_789')->make_path;
    $tmp->child('asset_dir_789')->child('file.txt')->spew('content');
    my $mock_ja = Test::MockObject->new;
    $mock_ja->set_always(asset => $mock_asset);
    my $mock_assets_rs = Test::MockObject->new;
    my @assets = ($mock_ja);
    $mock_assets_rs->mock(next => sub { shift @assets });
    $mock_job->set_always(jobs_assets => $mock_assets_rs);
    my $archive_path = OpenQA::Archive::create_job_archive($mock_job);
    ok -e $archive_path, 'Archive created with directory asset';
    my $mock_asset_missing = Test::MockObject->new;
    $mock_asset_missing->set_always(disk_file => $tmp->child('nonexistent_asset')->to_string);
    $mock_asset_missing->set_always(name => 'missing_asset');
    $mock_asset_missing->set_always(type => 'other');
    my $mock_ja_missing = Test::MockObject->new;
    $mock_ja_missing->set_always(asset => $mock_asset_missing);
    my @assets_missing = ($mock_ja_missing);
    $mock_assets_rs->mock(next => sub { shift @assets_missing });
    $mock_job->set_always(id => 7890);
    my $archive_path_missing = OpenQA::Archive::create_job_archive($mock_job);
    ok -e $archive_path_missing, 'Archive created even with missing asset file';
    my $archive_path2 = OpenQA::Archive::create_job_archive($mock_job);
    is $archive_path2->to_string, $archive_path_missing->to_string, 'Returned existing archive';
};

subtest 'Create archive failure' => sub {
    my $mock_job = Test::MockObject->new;
    $mock_job->set_always(id => 444);
    $mock_job->set_always(result_dir => undef);
    $mock_job->set_always(jobs_assets => Test::MockObject->new->set_always(next => undef));
    my $mock_zip_module = Test::MockModule->new('Archive::Zip::Archive');
    $mock_zip_module->mock(
        writeToFileNamed => sub {
            my ($self, $file) = @_;
            path($file)->spew('dummy');
            return AZ_IO_ERROR;
        });
    throws_ok { OpenQA::Archive::create_job_archive($mock_job) } qr/Failed to create archive/, 'Throws on zip failure';
};

subtest 'CreateZipArchive task' => sub {
    require OpenQA::Task::Job::CreateZipArchive;
    my $mock_minion_job = Test::MockObject->new;
    $mock_minion_job->set_always(app => $app);
    my $mock_schema_obj = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    $mock_schema_obj->set_always(resultset => $mock_rs);
    $mock_rs->set_always(find => undef);
    my $mock_app_module = Test::MockModule->new('OpenQA::WebAPI');
    $mock_app_module->mock(schema => sub { $mock_schema_obj });
    $mock_minion_job->set_true('finish');
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('finish', 'Finished with job not found message');
    my $mock_job = Test::MockObject->new;
    $mock_job->set_always(id => 4567);
    $mock_rs->set_always(find => $mock_job);
    my $mock_archive_module = Test::MockModule->new('OpenQA::Archive');
    $mock_archive_module->mock(create_job_archive => sub { path('/tmp/dummy.zip') });
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('finish', 'Finished successfully');
    $mock_archive_module->mock(create_job_archive => sub { die "creation error" });
    $mock_minion_job->set_true('fail');
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('fail', 'Failed correctly on error');
};

subtest 'Controller extra tests' => sub {
    my $job = $schema->resultset('Jobs')->create(
        {
            DISTRI => 'archtest',
            VERSION => '1.0',
            FLAVOR => 'test',
            ARCH => 'x86_64',
            TEST => 'job_fail',
            state => 'done',
            result => 'passed',
        });
    $t->get_ok('/archives/..%2fetc%2fpasswd')->status_is(404);
    $t->get_ok('/archives/nonexistent.zip')->status_is(404);
    my $mock_minion = Test::MockObject->new;
    my $mock_app_module = Test::MockModule->new('OpenQA::WebAPI');
    $mock_app_module->mock(minion => sub { $mock_minion });
    my $orig_can = $app->can('can');
    $mock_app_module->mock(
        can => sub ($self, $method) { return 1 if $method eq 'minion'; return $self->$orig_can($method); });
    my $mock_backend = Test::MockObject->new;
    $mock_minion->set_always(backend => $mock_backend);
    $mock_backend->set_always(list_jobs => {jobs => []});
    $mock_minion->set_true('enqueue');
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(200)->content_like(qr/Preparing Archive for Job/);
    $mock_minion->called_ok('enqueue', 'Minion job enqueued');
    $mock_minion->clear;
    $mock_backend->set_always(list_jobs => {jobs => [{id => 1}]});
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(200);
    ok !$mock_minion->called('enqueue'), 'Minion job NOT enqueued because it already exists';
    $mock_backend->set_always(list_jobs => sub { die "minion error" });
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(500);
};

done_testing;
