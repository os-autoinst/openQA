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

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $get = $t->get_ok('/api/v1/test_suites')->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'TestSuites' => [
            {
                'id'       => 1001,
                'name'     => 'textmode',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'textmode'
                    },
                    {
                        'key'   => 'VIDEOMODE',
                        'value' => 'text'
                    }]
            },
            {
                'id'       => 1002,
                'name'     => 'kde',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'kde'
                    }]
            },
            {
                'id'       => 1013,
                'name'     => 'RAID0',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key'   => 'INSTALLONLY',
                        'value' => '1'
                    },
                    {
                        'key'   => 'RAIDLEVEL',
                        'value' => '0'
                    }]
            },
            {
                'id'       => 1014,
                'name'     => 'client1',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key'   => 'PARALLEL_WITH',
                        'value' => 'server'
                    }]
            },
            {
                'id'       => 1015,
                'name'     => 'server',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'textmode'
                    }]
            },
            {
                'id'       => 1016,
                'name'     => 'client2',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'textmode'
                    },
                    {
                        'key'   => 'PARALLEL_WITH',
                        'value' => 'server'
                    }]
            },
            {
                'id'       => 1017,
                'name'     => 'advanced_kde',
                'settings' => [
                    {
                        'key'   => 'DESKTOP',
                        'value' => 'kde'
                    },
                    {
                        'key'   => 'PUBLISH_HDD_1',
                        'value' => '%DISTRI%-%VERSION%-%ARCH%-%DESKTOP%-%QEMUCPU%.qcow2'
                    },
                    {
                        'key'   => 'START_AFTER_TEST',
                        'value' => 'kde,textmode'
                    }]}]
    },
    "Initial test suites"
) || diag explain $get->tx->res->json;

$t->post_ok('/api/v1/test_suites', form => {})->status_is(400);    #no name


my $res = $t->post_ok(
    '/api/v1/test_suites',
    form => {
        name              => "testsuite",
        "settings[TEST]"  => "val1",
        "settings[TEST2]" => "val1"
    })->status_is(200);
my $test_suite_id = $res->tx->res->json->{id};

$res = $t->post_ok('/api/v1/test_suites', form => {name => "testsuite"})->status_is(400);    #already exists

$get = $t->get_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'TestSuites' => [
            {
                'id'       => $test_suite_id,
                'name'     => 'testsuite',
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
    "Add test_suite"
) || diag explain $get->tx->res->json;

$t->put_ok("/api/v1/test_suites/$test_suite_id", form => {name => "testsuite", "settings[TEST2]" => "val1"})->status_is(200);

$get = $t->get_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'TestSuites' => [
            {
                'id'       => $test_suite_id,
                'name'     => 'testsuite',
                'settings' => [
                    {
                        'key'   => 'TEST2',
                        'value' => 'val1'
                    }]}]
    },
    "Delete test_suite variable"
) || diag explain $get->tx->res->json;

$res = $t->delete_ok("/api/v1/test_suites/$test_suite_id")->status_is(200);
$res = $t->delete_ok("/api/v1/test_suites/$test_suite_id")->status_is(404);    #not found

done_testing();
