#!/usr/bin/env perl
# Copyright (C) 2017-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '16';
use OpenQA::Test::Case;
use OpenQA::Client;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->get_ok('/admin/workers.json');
my %workers = %{$t->tx->res->json->{workers}};
is(2, scalar(keys(%workers)), '2 workers seen');

done_testing();
