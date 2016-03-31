# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings ':all';
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Data::Dump;

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

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
    my $ret    = $t->get_ok('/api/v1/assets')->status_is(200);
    my @assets = @{$ret->tx->res->json->{assets}};
    for my $a (@assets) {
        printf "%d %-5s %s\n", $a->{id}, $a->{type}, $a->{name};
    }
}

my $ret;

my $iso1 = 'test-dvd-1.iso';
my $iso2 = 'test-dvd-2.iso';

for my $i ($iso1, $iso2) {
    ok(open(FH, '>', "t/data/openqa/factory/iso/$i"), "touch $i");
    close FH;
}

my $listing = [
    {
        id   => 6,
        name => $iso1,
        type => "iso",
        size => undef,
    },
    {
        id   => 7,
        name => $iso2,
        type => "iso",
        size => undef,
    },
];

la;

# register an iso
$ret = $t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($ret->tx->res->json->{id}, $listing->[0]->{id}, "asset has correct id");

# register same iso again yields same id
$ret = $t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($ret->tx->res->json->{id}, $listing->[0]->{id}, "asset still has correct id, no duplicate");

la;

# check data
$ret = $t->get_ok('/api/v1/assets/iso/' . $iso1)->status_is(200);
is_deeply(nots($ret->tx->res->json), $listing->[0], "asset correctly entered by name");
$ret = $t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200);
is_deeply(nots($ret->tx->res->json), $listing->[0], "asset correctly entered by id");

# check 404 for non existing isos
$ret = $t->get_ok('/api/v1/assets/iso/' . $iso2)->status_is(404);

# register a second one
$ret = $t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso2})->status_is(200);
is($ret->tx->res->json->{id}, $listing->[1]->{id}, "asset has corect id");

# check data
$ret = $t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200);
is_deeply(nots($ret->tx->res->json), $listing->[1], "asset correctly entered by id");

# check listing
$ret = $t->get_ok('/api/v1/assets')->status_is(200);
is_deeply(nots($ret->tx->res->json->{assets}->[5]), $listing->[0], "listing ok");

la;

# test delete operation
$ret = $t->delete_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(200);
is($ret->tx->res->json->{count}, 1, "one asset deleted");

# verify it's really gone
$ret = $t->get_ok('/api/v1/assets/' . $listing->[0]->{id})->status_is(404);
# but two must be still there
$ret = $t->get_ok('/api/v1/assets/' . $listing->[1]->{id})->status_is(200);

# register it again
$ret = $t->post_ok('/api/v1/assets', form => {type => 'iso', name => $iso1})->status_is(200);
is($ret->tx->res->json->{id}, $listing->[1]->{id} + 1, "asset has next id");

# delete by name
$ret = $t->delete_ok('/api/v1/assets/iso/' . $iso2)->status_is(200);
is($ret->tx->res->json->{count}, 1, "one asset deleted");
# but three must be still there
$ret = $t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200);

la;

# try to register with invalid type
like(warning { $ret = $t->post_ok('/api/v1/assets', form => {type => 'foo', name => $iso1})->status_is(400) }, qr/asset type \'foo\' invalid/);

# try to register non existing asset
like(warning { $ret = $t->post_ok('/api/v1/assets', form => {type => 'iso', name => 'foo.iso'})->status_is(400) }, qr/asset name \'foo.iso\' invalid/);

# switch to operator (percival) and try some modifications
$app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# test delete operation
$ret = $t->delete_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(403, 'asset deletion forbidden for operator');
# delete by name
$ret = $t->delete_ok('/api/v1/assets/iso/' . $iso1)->status_is(403, 'asset deletion forbidden for operator');
# asset must be still there
$ret = $t->get_ok('/api/v1/assets/' . ($listing->[1]->{id} + 1))->status_is(200);

for my $i ($iso1, $iso2) {
    ok(unlink("t/data/openqa/factory/iso/$i"), "rm $i");
}

done_testing();
