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


# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

# init test case
OpenQA::Test::Case->new->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;


path('t', 'client_tests.d')->remove_tree;
my $dir = path('t', 'client_tests.d', tempdir)->make_path;


# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
# $client->max_redirects(3);

$t->app($app);
$t->app->log->level('debug');
$t->ua->max_redirects(3);

my $base_url = $t->ua->server->url->to_string;

use Data::Dump;

subtest 'OpenQA::Client:Archive tests' => sub {
    my $jobid = 99938;
    diag $t->ua->server->url->path("/api/v1/jobs/$jobid");
    diag $dir->to_abs;

    my %options = (archive => $dir, url => "/api/v1/jobs/$jobid/details");
    $t->get_ok('/tests/99938/file/video.ogv');
    $t->ua->OpenQA::Client::Archive::run(%options);
    $t->get_ok('/tests/99938/file/video.ogv');

    is($@, '', '--archive 1234 would perform correctly' . $@);

};

done_testing();
