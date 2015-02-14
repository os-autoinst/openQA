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

my $get = $t->get_ok('/api/v1/job_templates')->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id' => 1,
                'machine' => {
                    'id' => 1001,
                    'name' => '32bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1001,
                    'name' => 'textmode'
                }
            },
            {
                'id' => 2,
                'machine' => {
                    'id' => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1002,
                    'name' => 'kde'
                }
            }
        ]
    },
    "Initial job templates"
) || diag explain $get->tx->res->json;


my $res = $t->post_ok('/api/v1/job_templates', form => { machine_id => 1001, test_suite_id => 1002, product_id=>1 })->status_is(200);
my $job_template_id1 = $res->tx->res->json->{id};

$res = $t->post_ok(
    '/api/v1/job_templates',
    form =>{
        machine_name => '64bit',
        test_suite_name => 'RAID0',
        'arch' => 'i586',
        'distri' => 'opensuse',
        'flavor' => 'DVD',
        'version' => '13.1'
    }
)->status_is(200);
my $job_template_id2 = $res->tx->res->json->{id};

$get = $t->get_ok("/api/v1/job_templates/$job_template_id1")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id' => $job_template_id1,
                'machine' => {
                    'id' => 1001,
                    'name' => '32bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1002,
                    'name' => 'kde'
                }
            }
          ]

    },
    "Initial job templates"
) || diag explain $get->tx->res->json;

$get = $t->get_ok("/api/v1/job_templates/$job_template_id2")->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id' => $job_template_id2,
                'machine' => {
                    'id' => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1013,
                    'name' => 'RAID0'
                }
            }
        ]
    },
    "Initial job templates"
) || diag explain $get->tx->res->json;

# search by name
$get = $t->get_ok("/api/v1/job_templates", form => { machine_name =>  '64bit', test_suite_name => 'RAID0', 'arch' => 'i586', 'distri' => 'opensuse', 'flavor' => 'DVD', 'version' => '13.1' })->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id' => $job_template_id2,
                'machine' => {
                    'id' => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1013,
                    'name' => 'RAID0'
                }
            }
        ]
    },
    "Initial job templates"
) || diag explain $get->tx->res->json;

#search all job templates with testsuite 'kde'
$get = $t->get_ok("/api/v1/job_templates", form => { test_suite_name => 'kde' })->status_is(200);
is_deeply(
    $get->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id' => 2,
                'machine' => {
                    'id' => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1002,
                    'name' => 'kde'
                }
            },
            {
                'id' => $job_template_id1,
                'machine' => {
                    'id' => 1001,
                    'name' => '32bit'
                },
                'product' => {
                    'arch' => 'i586',
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'id' => 1,
                    'version' => '13.1'
                },
                'test_suite' => {
                    'id' => 1002,
                    'name' => 'kde'
                }
            }
        ]
    },
    "Initial job templates"
) || diag explain $get->tx->res->json;


$res = $t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(200);
$res = $t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(404); #not found

$res = $t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(200);
$res = $t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(404); #not found

done_testing();
