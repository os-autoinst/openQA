#! /usr/bin/perl

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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Data::Dump;

use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ws = OpenQA::WebSockets->new;
my $sh = OpenQA::Scheduler->new;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $get = $t->get_ok('/api/v1/machines')->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'Machines' => [
            {
                'backend'  => 'qemu',
                'id'       => 1001,
                'name'     => '32bit',
                'settings' => [
                    {
                        'key'   => 'QEMUCPU',
                        'value' => 'qemu32'
                    }]
            },
            {
                'backend'  => 'qemu',
                'id'       => 1002,
                'name'     => '64bit',
                'settings' => [
                    {
                        'key'   => 'QEMUCPU',
                        'value' => 'qemu64'
                    }]
            },
            {
                'backend'  => 'qemu',
                'id'       => 1008,
                'name'     => 'Laptop_64',
                'settings' => [
                    {
                        'key'   => 'LAPTOP',
                        'value' => '1'
                    },
                    {
                        'key'   => 'QEMUCPU',
                        'value' => 'qemu64'
                    }]}]
    },
    "Initial machines"
) || diag explain $get->tx->res->json;


my $res = $t->post_ok('/api/v1/machines', form => {name => "testmachine"})->status_is(400);    # missing backend
$res = $t->post_ok('/api/v1/machines', form => {backend => "kde/usb"})->status_is(400);        #missing name

$res
  = $t->post_ok('/api/v1/machines',
    form => {name => "testmachine", backend => "qemu", "settings[TEST]" => "val1", "settings[TEST2]" => "val1"})
  ->status_is(200);
my $machine_id = $res->tx->res->json->{id};

$res = $t->get_ok('/api/v1/machines', form => {name => "testmachine"})->status_is(200);
is($res->tx->res->json->{Machines}->[0]->{id}, $machine_id);

$res
  = $t->post_ok('/api/v1/machines',
    form => {name => "testmachineQ", backend => "qemu", "settings[TEST]" => "'v'al1", "settings[TEST2]" => "va'l\'1"})
  ->status_is(200);
$res = $t->get_ok('/api/v1/machines', form => {name => "testmachineQ"})->status_is(200);
is($res->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");
is($res->tx->res->json->{Machines}->[0]->{settings}->[1]->{value}, "va'l\'1");

$t->post_ok('/api/v1/machines', form => {name => "testmachineZ", backend => "qemu", "settings[TE'S\'T]" => "'v'al1"})
  ->status_is(200);
$res = $t->get_ok('/api/v1/machines', form => {name => "testmachineQ"})->status_is(200);
is($res->tx->res->json->{Machines}->[0]->{settings}->[0]->{key},   "TEST");
is($res->tx->res->json->{Machines}->[0]->{settings}->[0]->{value}, "'v'al1");

$res
  = $t->post_ok('/api/v1/machines', form => {name => "testmachine", backend => "qemu"})->status_is(400); #already exists

$get = $t->get_ok("/api/v1/machines/$machine_id")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'Machines' => [
            {
                'backend'  => 'qemu',
                'id'       => $machine_id,
                'name'     => 'testmachine',
                'settings' => [
                    {
                        'key'   => 'TEST',
                        'value' => 'val1'
                    },
                    {
                        'key'   => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Add machine"
) || diag explain $get->tx->res->json;

$res = $t->put_ok("/api/v1/machines/$machine_id",
    form => {name => "testmachine", backend => "qemu", "settings[TEST2]" => "val1"})->status_is(200);

$get = $t->get_ok("/api/v1/machines/$machine_id")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'Machines' => [
            {
                'backend'  => 'qemu',
                'id'       => $machine_id,
                'name'     => 'testmachine',
                'settings' => [
                    {
                        'key'   => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Delete machine variable"
) || diag explain $get->tx->res->json;

$res = $t->delete_ok("/api/v1/machines/$machine_id")->status_is(200);
$res = $t->delete_ok("/api/v1/machines/$machine_id")->status_is(404);    #not found

# switch to operator (percival) and try some modifications
$app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->post_ok('/api/v1/machines',
    form => {name => "testmachine", backend => "qemu", "settings[TEST]" => "val1", "settings[TEST2]" => "val1"})
  ->status_is(403);
$t->put_ok("/api/v1/machines/$machine_id",
    form => {name => "testmachine", backend => "qemu", "settings[TEST2]" => "val1"})->status_is(403);
$t->delete_ok("/api/v1/machines/$machine_id")->status_is(403);

done_testing();
