#!/usr/bin/env perl

# Copyright (C) 2014-2017 SUSE LLC
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
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

sub nots {
    my $h  = shift;
    my @ts = @_;
    if (ref $h eq 'ARRAY') {
        my @r;
        for my $i (@$h) {
            push @r, nots($i, @ts);
        }
        return \@r;
    }
    unshift @ts, 't_updated', 't_created';
    for (@ts) {
        delete $h->{$_};
    }
    return $h;
}

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

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
        id              => 7,
        name            => $iso1,
        type            => "iso",
        size            => undef,
        checksum        => undef,
        last_use_job_id => undef,
        fixed           => 0,
    },
    {
        id              => 8,
        name            => $iso2,
        type            => "iso",
        size            => undef,
        checksum        => undef,
        last_use_job_id => undef,
        fixed           => 0,
    },
];

la;

# register an iso
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($t->tx->res->json->{id}, $listing->[0]->{id}, "asset has correct id");

# register same iso again yields same id
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($t->tx->res->json->{id}, $listing->[0]->{id}, "asset still has correct id, no duplicate");

la;

# check data
$t->get_ok('/api/v1/assets/iso/' . $iso1)->status_is(200);
is_deeply(nots($t->tx->res->json), $listing->[0], "asset correctly entered by name");
$t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200);
is_deeply(nots($t->tx->res->json), $listing->[0], "asset correctly entered by id");

# check 404 for non existing isos
$t->get_ok('/api/v1/assets/iso/' . $iso2)->status_is(404);

# register a second one
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso2})->status_is(200);
is($t->tx->res->json->{id}, $listing->[1]->{id}, "asset has corect id");

# check data
$t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200);
is_deeply(nots($t->tx->res->json), $listing->[1], "asset correctly entered by id");

# check listing
$t->get_ok('/api/v1/assets')->status_is(200);
is_deeply(nots($t->tx->res->json->{assets}->[6]), $listing->[0], "listing ok");

la;

# test delete operation
$t->delete_ok('/api/v1/assets/1a')->status_is(400);
$t->delete_ok('/api/v1/assets/99')->status_is(404);
$t->delete_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200);
is($t->tx->res->json->{count}, 1, "one asset deleted");

# verify it's really gone
$t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(404);
ok(!-e iso_path($iso1), 'iso file 1 has been removed');
# but two must be still there
$t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200);
ok(-e iso_path($iso2), 'iso file 2 is still there');

# register it again
touch_isos [$iso1];
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($t->tx->res->json->{id}, $listing->[1]->{id} + 1, "asset has next id");

# delete by name
$t->delete_ok('/api/v1/assets/iso/' . $iso2)->status_is(200);
ok(!-e iso_path($iso2), 'iso file 2 has been removed');
# but three must be still there
$t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200);

la;

# try to register with invalid type
$t->post_ok('/api/v1/assets', form => {type => 'foo', name => $iso1})->status_is(400);

# try to register with invalid name
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => ''})->status_is(400);

# try to register non existing asset
$t->post_ok('/api/v1/assets', form => {type => 'iso', name => 'foo.iso'})->status_is(400);

# check/delete asset by invalid id that should give 404 rather than 500
$t->get_ok('/api/v1/assets/iso')->status_is(404);
$t->delete_ok('/api/v1/assets/iso')->status_is(400);

# trigger cleanup task
my $gru       = $t->app->gru;
my $gru_tasks = $t->app->schema->resultset('GruTasks');
$t->app->minion->reset;    # be sure no 'limit_assets' tasks have already been enqueued
is($gru->count_jobs(limit_assets => ['inactive']), 0, 'is_task_active returns 0 if not tasks enqueued');
is($gru_tasks->count,                              0, 'no gru tasks present so far');
$t->post_ok('/api/v1/assets/cleanup')->status_is(200)->json_is('/status' => 'ok', 'status ok');
is($gru_tasks->count, 1, 'gru task added')
  and is($gru_tasks->first->taskname, 'limit_assets', 'right gru task added');
is($gru->count_jobs(limit_assets => ['inactive']), 1, 'is_task_active returns 1 after task enqueued');
$t->post_ok('/api/v1/assets/cleanup')->status_is(200)->json_is('/status' => 'ok', 'status ok')
  ->json_is('/gru_id' => undef);
is($gru_tasks->count, 1, 'no further task if one was already enqueued');

# switch to operator (percival) and try some modifications
$app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# test delete operation
$t->delete_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(403, 'asset deletion forbidden for operator');
# delete by name
$t->delete_ok('/api/v1/assets/iso/' . $iso1)->status_is(403, 'asset deletion forbidden for operator');
# asset must be still there
$t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200);
ok(-e iso_path($iso1),      'iso file 1 is still there');
ok(unlink(iso_path($iso1)), 'remove iso file 1 manually');

done_testing();
