#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'), apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');

sub la {
    return unless $ENV{HARNESS_IS_VERBOSE};
    $t->get_ok('/api/v1/assets')->status_is(200);
    my @assets = @{$t->tx->res->json->{assets}};
    for my $asset (@assets) {
        printf "%d %-5s %s\n", $asset->{id}, $asset->{type}, $asset->{name};
    }
}

sub iso_path {
    my ($iso) = @_;
    return "t/data/openqa/share/factory/iso/$iso";
}

sub touch_isos {
    my ($isos) = @_;
    for my $iso (@$isos) {
        ok(open(FH, '>', iso_path($iso)), "touch $iso");
        close FH;
    }
}
my $iso1 = 'test-dvd-1.iso';
my $iso2 = 'test-dvd-2.iso';
touch_isos [$iso1, $iso2];

my $listing = [
    {
        name => $iso1,
        type => "iso",
        size => undef,
        checksum => undef,
        last_use_job_id => undef,
        fixed => 0,
    },
    {
        name => $iso2,
        type => "iso",
        size => undef,
        checksum => undef,
        last_use_job_id => undef,
        fixed => 0,
    },
];

la;

$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200, 'iso registered');
$listing->[0]->{id} = $t->tx->res->json->{id};
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200, 'register iso again')
  ->json_is('/id' => $listing->[0]->{id}, 'iso has the same ID, no duplicate');

la;

# check data
$t->get_ok('/api/v1/assets/iso/' . $iso1)->status_is(200);
delete $t->tx->res->json->{$_} for qw/t_updated t_created/;
$t->json_is('' => $listing->[0], "asset correctly entered by name");
$t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200);
delete $t->tx->res->json->{$_} for qw/t_updated t_created/;
$t->json_is('' => $listing->[0], "asset correctly entered by id");
$t->get_ok('/api/v1/assets/iso/' . $iso2)->status_is(404, 'iso does not exist');

$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso2})->status_is(200, 'second asset posted');
$listing->[1]->{id} = $t->tx->res->json->{id};
isnt($listing->[0]->{id}, $listing->[1]->{id}, 'new assets has a distinct ID');

# check data
$t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200);
delete $t->tx->res->json->{$_} for qw/t_updated t_created/;
$t->json_is('' => $listing->[1], "asset correctly entered by ID");

# check listing
$t->get_ok('/api/v1/assets')->status_is(200);
delete $t->tx->res->json->{assets}->[6]->{$_} for qw/t_updated t_created/;
$t->json_is('/assets/6' => $listing->[0], "listing ok");

la;

# test delete operation
$t->delete_ok('/api/v1/assets/1a')->status_is(404, 'assert with invalid ID');
$t->delete_ok('/api/v1/assets/99')->status_is(404, 'asset does not exist');
$t->delete_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200, 'asset deleted')
  ->json_is('/count' => 1, "one asset deleted");

$t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(404, 'asset was deleted');
ok(!-e iso_path($iso1), 'iso file 1 has been removed');
$t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200, 'second asset remains');
ok(-e iso_path($iso2), 'iso file 2 is still there');

touch_isos [$iso1];
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200, 'registering again works')
  ->json_is('/id' =>, $listing->[1]->{id} + 1, "asset has next id");

$t->delete_ok('/api/v1/assets/iso/' . $iso2)->status_is(200, 'delete asset by name');
ok(!-e iso_path($iso2), 'iso file 2 has been removed');
$t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200, 'third asset remains');

la;

$t->post_ok('/api/v1/assets', form => {type => 'foo', name => $iso1})->status_is(400, 'invalid type is an error');
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => ''})
  ->status_is(400, 'posting asset with invalid name fails');
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => 'foo.iso'})
  ->status_is(400, 'registering non-existing asset fails');

$t->get_ok('/api/v1/assets/iso')->status_is(404, 'getting asset without name is an error');
$t->delete_ok('/api/v1/assets/iso')->status_is(404, 'deleting without name is an error');

# trigger cleanup task
my $gru = $t->app->gru;
my $gru_tasks = $t->app->schema->resultset('GruTasks');
$t->app->minion->reset;    # be sure no 'limit_assets' tasks have already been enqueued
is($gru->count_jobs(limit_assets => ['inactive']), 0, 'is_task_active returns 0 if not tasks enqueued');
is($gru_tasks->count, 0, 'no gru tasks present so far');
$t->post_ok('/api/v1/assets/cleanup')->status_is(200)->json_is('/status' => 'ok', 'status ok');
is($gru_tasks->count, 1, 'gru task added')
  and is($gru_tasks->first->taskname, 'limit_assets', 'right gru task added');
is($gru->count_jobs(limit_assets => ['inactive']), 1, 'is_task_active returns 1 after task enqueued');
$t->post_ok('/api/v1/assets/cleanup')->status_is(200)->json_is('/status' => 'ok', 'status ok')
  ->json_is('/gru_id' => undef);
is($gru_tasks->count, 1, 'no further task if one was already enqueued');

# switch to operator (default client) and try some modifications
client($t);

# test delete operation
$t->delete_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(403, 'asset deletion forbidden for operator');
$t->delete_ok('/api/v1/assets/iso/' . $iso1)->status_is(403, 'asset deletion forbidden for operator');
$t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200, 'asset is still there');
ok(-e iso_path($iso1), 'iso file 1 is still there');
ok(unlink(iso_path($iso1)), 'remove iso file 1 manually');

done_testing();
