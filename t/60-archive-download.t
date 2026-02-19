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
    $t->get_ok('/tests/' . $job->id . '/archive')->status_is(200)->content_type_is('application/zip')
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
    $t->get_ok('/tests/' . $job_id . '/archive')->status_is(200);
    is $cache_file->stat->mtime, $mtime, 'Cached file was reused';
};

done_testing;
