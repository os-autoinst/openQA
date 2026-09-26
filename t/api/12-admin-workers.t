#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use DateTime;
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Client;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->get_ok('/admin/workers.json');
my %workers = %{$t->tx->res->json->{workers}};
is 2, scalar(keys %workers), '2 workers seen';

$t->app->schema->resultset('Workers')->update({t_seen => DateTime->now(time_zone => 'UTC')});

subtest 'Worker host administration endpoints' => sub {
    my $worker = $t->app->schema->resultset('Workers')->find({host => 'localhost', instance => 1});
    $worker->set_property('WORKER_CLASS', 'class1,class2');

    $t->get_ok('/admin/worker_hosts/localhost', {Accept => 'application/json'})
      ->status_is(200, 'GET on valid host JSON endpoint returns 200 OK')
      ->json_is('/worker_host' => 'localhost', 'JSON response contains correct host name')
      ->json_is('/stats/online' => 1, 'JSON response contains correct count of online workers')
      ->json_is('/worker_classes/0' => 'class1', 'JSON response contains correct first class')
      ->json_is('/worker_classes/1' => 'class2', 'JSON response contains correct second class');

    $t->get_ok('/admin/worker_hosts/nonexistent', {Accept => 'application/json'})
      ->status_is(404, 'GET on nonexistent host JSON endpoint returns 404 Not Found');

    $t->get_ok('/admin/worker_hosts/localhost/ajax')
      ->status_is(200, 'GET on host previous jobs ajax endpoint returns 200 OK')
      ->json_has('/data', 'JSON response contains datatable data array');
};

done_testing();
