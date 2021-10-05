#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
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
use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Client;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');

my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

$t->delete_ok('/api/v1/user/99904')->status_is(200, 'admins can delete users');
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'user_deleted'),
    {username => 'Demo'},
    'Delete was logged correctly'
);

$t->delete_ok('/api/v1/user/99999')->status_is(404, 'a non-existent user cannot be deleted');

$t->ua(OpenQA::Client->new(apikey => 'LANCELOTKEY01', apisecret => 'MANYPEOPLEKNOW')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->delete_ok('/api/v1/user/99904')->status_is(403, 'non-admins cannot delete users');

done_testing();
