# Copyright (C) 2018 SUSE LLC
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
# You should have received a copy of the GNU General Public License

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "lib";

use Test::More;
use Test::Mojo;
use Mojo::URL;
use Test::Warnings;
use OpenQA::Client;
use OpenQA::Client::Archive;
use OpenQA::WebAPI;
use Mojo::File qw(tempfile tempdir path);
use OpenQA::Test::Case;

# init test case
OpenQA::Test::Case->new->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
my $base_url = $t->ua->server->url->to_string;

path('t', 'client_tests.d')->remove_tree;
my $destination = path('t', 'client_tests.d', tempdir)->make_path;

subtest 'OpenQA::Client:Archive tests' => sub {
    my $jobid = 99938;

    my $command = $t->ua->archive->run({archive => $destination, url => "/api/v1/jobs/$jobid/details"});

    is($@, '', 'Archive functionality works as expected would perform correctly' . $@);
    my $file = path($destination, 'testresults', 'details-zypper_up.json');
    ok(-e $file, 'details-zypper_up.json file exists') or diag $file;
    $file = path($destination, 'testresults', 'video.ogv');
    ok(-e $file, 'Test video file exists') or diag $file;
    $file = path($destination, 'testresults','ulogs', 'y2logs.tar.bz2');
    ok(-e $file, 'Test uploaded logs file exists') or diag $file;

};

done_testing();
