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

subtest 'ZIP archive download and categorization' => sub {
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
    my $res_dir = path($job->create_result_dir);
    $res_dir->child('vars.json')->spew('{"test": "data"}');
    $res_dir->child('ulogs')->make_path->child('test.log')->spew('log data');
    my $asset = $schema->resultset('Assets')->create({type => 'iso', name => 'test.iso'});
    $schema->resultset('JobsAssets')->create({job_id => $job->id, asset_id => $asset->id});
    path(assetdir(), 'iso', 'test.iso')->dirname->make_path->child('test.iso')->spew('iso data');

    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(302)
      ->header_is('Location' => '/login?return_page=%2Ftests%2F' . $job->id . '%2Farchive');
    $t->get_ok('/');
    ok $case->login($t, 'admin'), 'Admin login succeeds';

    my @test_cases = (
        {
            category => 'all',
            expected => [qw(testresults/vars.json testresults/ulogs/test.log iso/test.iso)],
        },
        {
            category => 'resultfiles',
            expected => ['testresults/vars.json'],
            unexpected => [qw(testresults/ulogs/test.log iso/test.iso)],
        },
        {
            category => 'ulogs',
            expected => ['testresults/ulogs/test.log'],
            unexpected => [qw(testresults/vars.json iso/test.iso)],
        },
        {
            category => 'assets',
            expected => ['iso/test.iso'],
            unexpected => [qw(testresults/vars.json testresults/ulogs/test.log)],
        },
    );

    for my $tc (@test_cases) {
        my $cat = $tc->{category};
        my $url = '/tests/' . $job->id . '/archive' . ($cat eq 'all' ? '' : "?category=$cat");
        my $suffix = $cat eq 'all' ? '' : "_$cat";

        $t->get_ok($url)->status_is(302)->header_like('Location' => qr|/archives/job_@{[ $job->id ]}${suffix}\.zip|);
        $t->get_ok($t->tx->res->headers->location)->status_is(200)->content_type_is('application/zip');

        my $zip = Archive::Zip->new();
        my $content = $t->tx->res->body;
        open my $fh, '<', \$content;
        is $zip->read($fh), AZ_OK, "ZIP archive for category '$cat' is structurally valid";

        ok $zip->memberNamed($_), "Category '$cat' archive correctly includes: $_" for @{$tc->{expected}};
        ok !$zip->memberNamed($_), "Category '$cat' archive correctly excludes: $_" for @{$tc->{unexpected} // []};
    }
};

subtest 'Archive with large files' => sub {
    my $job = $schema->resultset('Jobs')->create(
        {
            DISTRI => 'archtest',
            VERSION => '1.0',
            FLAVOR => 'test',
            ARCH => 'x86_64',
            TEST => 'large_job',
            state => 'done',
            result => 'passed',
        });
    my $res_dir = path($job->create_result_dir);
    my $large_file = $res_dir->child('large.bin');
    my $fh = $large_file->open('>');
    print $fh 'A' x 1024 for 1 .. 50 * 1024;
    $fh->close;

    my $archive_path = OpenQA::Archive::create_job_archive($job);
    ok -e $archive_path, 'Archive with 50MB file created successfully';
    my $zip = Archive::Zip->new();
    is $zip->read($archive_path->to_string), AZ_OK, 'Large ZIP archive is readable';
    my $member = $zip->memberNamed('testresults/large.bin');
    ok $member, 'ZIP archive contains the large file';
    is $member->uncompressedSize, 50 * 1024 * 1024, 'Archived file size matches expected 50MB';
};

subtest 'Archive caching' => sub {
    my $job_id = $schema->resultset('Jobs')->first->id;
    my $cache_file = path($ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR})->child("job_$job_id.zip");
    ok -e $cache_file, 'Initial archive exists in cache';
    my $mtime = $cache_file->stat->mtime;
    utime $mtime - 10, $mtime - 10, $cache_file->to_string;
    $mtime = $cache_file->stat->mtime;
    $t->get_ok('/tests/' . $job_id . '/archive')->status_is(302);
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    is $cache_file->stat->mtime, $mtime, 'Archive request reuses existing cached file without regeneration';
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
      'Archive cache directory follows application config';
    is OpenQA::Archive::get_cache_limit(), 1024 * 1024 * 1024, 'Cache size limit is correctly converted to bytes';
    is OpenQA::Archive::get_min_free_percentage(), 20, 'Minimum free space percentage follows config';
    is OpenQA::Archive::get_watermark_percentage(), 50, 'Cleanup watermark percentage follows config';
    ok OpenQA::Archive::is_cache_limit_exceeded(2 * 1024 * 1024 * 1024, 100, 1000),
      'Cache limit is exceeded when current size is over threshold';
    ok OpenQA::Archive::is_cache_limit_exceeded(100, 10, 100),
      'Cache limit is exceeded when free disk space is below minimum';
    ok !OpenQA::Archive::is_cache_limit_exceeded(100, 30, 100),
      'Cache limit is not exceeded when within safety thresholds';
    delete $app->config->{job_details_archive}->{job_details_archive_cache_dir};
    like OpenQA::Archive::archive_cache_dir(), qr|/webui/cache/archives$|, 'Fallback to default cache directory works';
    delete $app->config->{job_details_archive};
    is OpenQA::Archive::get_cache_limit(), 5 * 1024 * 1024 * 1024, 'Default cache limit is 5GB';
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
    my $now = time;
    for my $i (100 .. 105) {
        my $f = $cache_dir->child("job_$i.zip");
        $f->spew("data $i" . ('x' x 100000));
        utime $now - (200 - $i), $now - (200 - $i), $f->to_string;
    }
    my @initial = $cache_dir->list->grep(sub { $_->basename =~ /^job_\d+\.zip$/ })->each;
    OpenQA::Archive::cleanup_cache();
    my @remaining = $cache_dir->list->grep(sub { $_->basename =~ /^job_\d+\.zip$/ })->each;
    ok scalar(@remaining) < scalar(@initial), 'Archive cache is rotated after exceeding limit';
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
    ok -e $archive_path, 'Archive is created correctly when an asset is a directory';

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
    ok -e $archive_path_missing, 'Archive creation succeeds even if an asset file is missing from disk';
    my $archive_path2 = OpenQA::Archive::create_job_archive($mock_job);
    is $archive_path2->to_string, $archive_path_missing->to_string,
      'Archive request returns existing file if already present in cache';
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
    throws_ok { OpenQA::Archive::create_job_archive($mock_job) } qr/Failed to create archive/,
      'Archive creation throws error on ZIP library failure';
};

subtest 'CreateZipArchive Minion task' => sub {
    require OpenQA::Task::Job::CreateZipArchive;
    my $mock_minion_job = Test::MockObject->new->set_always(app => $app)->set_true('finish')->set_true('fail');
    my $mock_schema_obj = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    $mock_schema_obj->set_always(resultset => $mock_rs);
    $mock_rs->set_always(find => undef);

    my $mock_app_module = Test::MockModule->new('OpenQA::WebAPI');
    $mock_app_module->mock(schema => sub { $mock_schema_obj });
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('finish', 'Task finishes gracefully if job is not found in database');

    my $mock_job = Test::MockObject->new->set_always(id => 4567);
    $mock_rs->set_always(find => $mock_job);
    my $mock_archive_module = Test::MockModule->new('OpenQA::Archive');
    $mock_archive_module->mock(create_job_archive => sub { path('/tmp/dummy.zip') });
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('finish', 'Task completes successfully after archive generation');

    $mock_archive_module->mock(create_job_archive => sub { die 'creation error' });
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    $mock_minion_job->called_ok('fail', 'Task fails correctly when archive generation logic throws an exception');

    # Verify create_zip_archive_limit config is respected
    my $mock_minion = Test::MockModule->new('Minion');
    my @guard_calls;
    $mock_minion->mock(
        guard => sub {
            my ($self, $name, $duration, $options) = @_;
            push @guard_calls, {name => $name, duration => $duration, options => $options};
            return 'mock_guard';
        });
    my $orig_limit = $app->config->{misc_limits}->{create_zip_archive_limit};

    # default limit (2)
    delete $app->config->{misc_limits}->{create_zip_archive_limit};
    $mock_archive_module->mock(create_job_archive => sub { path('/tmp/dummy.zip') });
    @guard_calls = ();
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    is_deeply \@guard_calls, [{name => 'create_zip_archive_task', duration => 86400, options => {limit => 2}}],
      'called guard with default limit';

    # custom configured limit (5)
    $app->config->{misc_limits}->{create_zip_archive_limit} = 5;
    @guard_calls = ();
    OpenQA::Task::Job::CreateZipArchive::_create_zip_archive($mock_minion_job, 4567);
    is_deeply \@guard_calls, [{name => 'create_zip_archive_task', duration => 86400, options => {limit => 5}}],
      'called guard with custom configured limit';

    $app->config->{misc_limits}->{create_zip_archive_limit} = $orig_limit;
    $mock_minion->unmock_all;
};

subtest 'Controller archive endpoint' => sub {
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

    my $mock_minion = Test::MockObject->new->set_true('enqueue');
    my $mock_app_module = Test::MockModule->new('OpenQA::WebAPI');
    $mock_app_module->mock(minion => sub { $mock_minion });
    my $orig_can = $app->can('can');
    $mock_app_module->mock(
        can => sub ($self, $method) {
            return 1 if $method eq 'minion';
            return $orig_can ? $self->$orig_can($method) : UNIVERSAL::can($self, $method);    ## no critic (ProhibitUniversalCan)
        });
    $mock_minion->set_true('enqueue');

    $case->login($t, 'admin');
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(200)->content_like(qr/Preparing Archive for Job/);
    $mock_minion->called_ok('enqueue', 'Archive generation is enqueued in Minion');
    $mock_minion->clear;
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(200);
    $mock_minion->called_ok('enqueue', 'Repeated archive request re-enqueues generation task');

    $mock_minion->mock(enqueue => sub { die 'Enqueue failed' });
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(500)->content_is('Internal Server Error');
};

subtest 'Category specific archives' => sub {
    my $job = $schema->resultset('Jobs')->create(
        {
            DISTRI => 'archtest',
            VERSION => '1.0',
            FLAVOR => 'test',
            ARCH => 'x86_64',
            TEST => 'category_test',
            state => 'done',
            result => 'passed',
        });
    my $res_dir = path($job->create_result_dir);
    $res_dir->child('vars.json')->spew('{}');    # COMMON_RESULT_FILES includes vars.json
    $res_dir->child('ulogs')->make_path->child('ulog.txt')->spew('ulog data');
    my $asset = $schema->resultset('Assets')->create({type => 'iso', name => 'asset.iso'});
    $schema->resultset('JobsAssets')->create({job_id => $job->id, asset_id => $asset->id});
    path(assetdir(), 'iso', 'asset.iso')->dirname->make_path->child('asset.iso')->spew('asset data');

    $case->login($t, 'admin');

    # Test resultfiles category
    $t->get_ok('/tests/' . $job->id . '/archive?category=resultfiles')->status_is(302)
      ->header_like('Location' => qr|/archives/job_\d+_resultfiles.zip|);
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    my $zip_file = $tmp->child('resultfiles.zip');
    $zip_file->spew($t->tx->res->body);
    my $zip = Archive::Zip->new();
    is $zip->read($zip_file->to_string), AZ_OK, 'Resultfiles zip is valid';
    ok $zip->memberNamed('testresults/vars.json'), 'Contains result file';
    ok !$zip->memberNamed('testresults/ulogs/ulog.txt'), 'Does not contain ulog';
    ok !$zip->memberNamed('iso/asset.iso'), 'Does not contain asset';

    # Test ulogs category
    $t->get_ok('/tests/' . $job->id . '/archive?category=ulogs')->status_is(302)
      ->header_like('Location' => qr|/archives/job_\d+_ulogs.zip|);
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    $zip_file = $tmp->child('ulogs.zip');
    $zip_file->spew($t->tx->res->body);
    $zip = Archive::Zip->new();
    is $zip->read($zip_file->to_string), AZ_OK, 'Ulogs zip is valid';
    ok !$zip->memberNamed('testresults/vars.json'), 'Does not contain result file';
    ok $zip->memberNamed('testresults/ulogs/ulog.txt'), 'Contains ulog';
    ok !$zip->memberNamed('iso/asset.iso'), 'Does not contain asset';

    # Test assets category
    $t->get_ok('/tests/' . $job->id . '/archive?category=assets')->status_is(302)
      ->header_like('Location' => qr|/archives/job_\d+_assets.zip|);
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    $zip_file = $tmp->child('assets.zip');
    $zip_file->spew($t->tx->res->body);
    $zip = Archive::Zip->new();
    is $zip->read($zip_file->to_string), AZ_OK, 'Assets zip is valid';
    ok !$zip->memberNamed('testresults/vars.json'), 'Does not contain result file';
    ok !$zip->memberNamed('testresults/ulogs/ulog.txt'), 'Does not contain ulog';
    ok $zip->memberNamed('iso/asset.iso'), 'Contains asset';
};

done_testing;
