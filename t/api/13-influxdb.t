#!/usr/bin/env perl -w

# Copyright (C) 2018 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::WebSockets;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $app = $t->app;
# we don't need API keys for this route
$t->app($app);
$app->config->{global}->{base_url} = 'http://example.com';

my $get = $t->get_ok('/admin/influxdb/jobs');
is(
    $get->tx->res->body,
    "openqa_jobs,url=http://example.com blocked=0i,running=2i,scheduled=2i
openqa_jobs_by_group,url=http://example.com,group=No\\ Group scheduled=1i
openqa_jobs_by_group,url=http://example.com,group=opensuse running=1i,scheduled=1i
openqa_jobs_by_group,url=http://example.com,group=opensuse\\ test running=1i
openqa_jobs_by_arch,url=http://example.com,arch=i586 scheduled=2i
openqa_jobs_by_arch,url=http://example.com,arch=x86_64 running=2i
", "matches"
);

done_testing();
