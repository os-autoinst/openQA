#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Client;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->get_ok('/admin/workers.json');
my %workers = %{$t->tx->res->json->{workers}};
is 2, scalar(keys %workers), '2 workers seen';

subtest 'show impact factors on admin worker page' => sub {
    my $t_web = Test::Mojo->new('OpenQA::WebAPI');
    $t_web->get_ok('/');
    $test_case->login($t_web, 'percival');
    my $worker = $app->schema->resultset('Workers')->find(1);
    $worker->set_property('JOB_IMPACT_SLOT_POWER_W', 150);

    $t_web->get_ok('/admin/workers/1')->status_is(200, 'admin worker details page rendered')
      ->content_like(qr/JOB_IMPACT_SLOT_POWER_W/, 'impact factor key shown in properties table')
      ->content_like(qr/150/, 'impact factor value shown in properties table')
      ->element_exists('table.table-striped a[href="https://open.qa/docs/#jobimpact"]',
        'documentation link for impact factor present');
};

done_testing();
