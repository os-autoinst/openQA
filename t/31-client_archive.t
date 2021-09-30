# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';

use Test::More;
use Test::Mojo;
use OpenQA::Client::Archive;
use Mojo::File qw(tempdir path);
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $destination = tempdir;

subtest 'OpenQA::Client:Archive tests' => sub {
    my $jobid = 99938;
    my $limit = 1024 * 1024;
    my $limittest_path = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults', '00099',
        '00099938-opensuse-Factory-DVD-x86_64-Build0048-doc', 'ulogs');


    my $dd_output = `dd if=/dev/zero of=$limittest_path/limittest.tar.bz2 bs=1M count=2 2>&1`;
    is(-s "$limittest_path/limittest.tar.bz2", 2 * 1024 * 1024, 'limit test file is created')
      or note "dd output: $dd_output";

    eval {
        my %options = (
            archive => $destination,
            url => "/api/v1/jobs/$jobid/details",
            'asset-size-limit' => $limit,
            'with-thumbnails' => 1
        );
        my $command = $t->ua->archive->run(\%options);
    };
    is($@, '', 'Archive functionality works as expected would perform correctly') or diag explain $@;

    my $file = $destination->child('testresults', 'details-zypper_up.json');
    ok(-e $file, 'details-zypper_up.json file exists') or diag $file;
    $file = $destination->child('testresults', 'video.ogv');

    ok(-e $file, 'Test video file exists') or diag $file;
    $file = $destination->child('testresults', 'ulogs', 'y2logs.tar.bz2');

    ok(-e $file, 'Test uploaded logs file exists') or diag $file;
    $file = $destination->child('testresults', 'ulogs', 'limittest.tar.bz2');

    ok(!-e $file, 'Test uploaded logs file was not created') or diag $file;
    is($t->ua->max_response_size, $limit, "Max response size for UA is correct ($limit)");

};

done_testing();
