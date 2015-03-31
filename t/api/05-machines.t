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
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Data::Dump;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
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

$res = $t->post_ok('/api/v1/machines', form => {name => "testmachine", backend => "qemu", "settings[TEST]" => "val1", "settings[TEST2]" => "val1"})->status_is(200);
my $machine_id = $res->tx->res->json->{id};

$res = $t->get_ok('/api/v1/machines', form => {name => "testmachine"})->status_is(200);
is($res->tx->res->json->{Machines}->[0]->{id}, $machine_id);

$res = $t->post_ok('/api/v1/machines', form => {name => "testmachine", backend => "qemu"})->status_is(400);    #already exists

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

$res = $t->put_ok("/api/v1/machines/$machine_id", form => {name => "testmachine", backend => "qemu", "settings[TEST2]" => "val1"})->status_is(200);

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

done_testing();
