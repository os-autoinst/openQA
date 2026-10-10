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

subtest 'Worker status template rendering with reservation' => sub {
    $t->app->schema->txn_begin;
    my $idle_worker = $t->app->schema->resultset('Workers')->create(
        {
            host => 'reserved_host',
            instance => 1,
            t_seen => DateTime->now(time_zone => 'UTC'),
        });
    $idle_worker->set_property(RESERVED_BY_ID => 1);
    $idle_worker->set_property(RESERVED_WORKER_CLASS => 'special_class');
    $idle_worker->set_property(RESERVED_T_EXPIRES => time + 3600);

    $t->get_ok('/admin/workers', {Accept => 'text/html'})
      ->status_is(200, 'GET on admin workers page with class reservation returns 200 OK')
      ->content_like(qr/Reserved \(class special_class\)/, 'worker status includes reservation class');

    $t->get_ok('/admin/workers/' . $idle_worker->id, {Accept => 'text/html'})
      ->status_is(200, 'GET on admin worker show page returns 200 OK')
      ->content_like(qr/Reserved \(class special_class\)/, 'worker status on show page includes reservation class');

    $t->get_ok('/admin/worker_hosts/reserved_host', {Accept => 'text/html'})
      ->status_is(200, 'GET on admin worker host show page returns 200 OK')
      ->content_like(qr/Reserved \(class special_class\)/,
        'worker status on host show page includes reservation class');

    $idle_worker->delete_properties(['RESERVED_WORKER_CLASS']);
    $t->get_ok('/admin/workers', {Accept => 'text/html'})
      ->status_is(200, 'GET on admin workers page without class reservation returns 200 OK')
      ->content_like(qr/Reserved\s*<a\s+class="help_popover/,
        'worker status displays plain Reserved when worker class is unset')
      ->content_unlike(qr/Reserved \(class/, 'worker status does not contain class when worker class is unset');
    $t->app->schema->txn_rollback;
};

subtest 'Host previous jobs are sorted by finish time, not by an unrelated column' => sub {
    $t->app->schema->txn_begin;
    my $worker_id = $t->app->schema->resultset('Workers')->find({host => 'localhost', instance => 1})->id;
    my $jobs = $t->app->schema->resultset('Jobs');
    my $older = $jobs->create(
        {
            DISTRI => 'opensuse',
            VERSION => 'v1',
            FLAVOR => 'zzz',
            ARCH => 'x86_64',
            TEST => 'ordering',
            state => 'queued',
            result => 'none',
            assigned_worker_id => $worker_id,
            t_finished => DateTime->new(year => 2020, month => 1, day => 1),
        });
    my $newer = $jobs->create(
        {
            DISTRI => 'opensuse',
            VERSION => 'v1',
            FLAVOR => 'aaa',
            ARCH => 'x86_64',
            TEST => 'ordering',
            state => 'queued',
            result => 'none',
            assigned_worker_id => $worker_id,
            t_finished => DateTime->new(year => 2025, month => 1, day => 1),
        });

    $t->get_ok('/admin/worker_hosts/localhost/ajax?order%5B0%5D%5Bcolumn%5D=3&order%5B0%5D%5Bdir%5D=desc')
      ->status_is(200, 'sorting by 4th display column (Finished) descending returns 200 OK');
    my $data = $t->tx->res->json->{data};
    is $data->[0]{id}, $newer->id, 'most recently finished job is listed first';
    is $data->[1]{id}, $older->id, 'older job listed after the most recent one';
    ok $data->[0]{finished} gt $data->[1]{finished}, 'finished times are ordered descending';
    $t->app->schema->txn_rollback;
};

done_testing();
