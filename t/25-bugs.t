#!/usr/bin/env perl -w

# Copyright (C) 2017 SUSE Linux LLC
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
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;

OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $t = Test::Mojo->new('OpenQA::WebAPI');


my $bug = OpenQA::Schema::Result::Bugs->get_bug('poo#200', $t->app->db);
ok(!defined $bug, 'bug not refreshed');

$t->app->schema->resultset('Bugs')->find(1)->update({refreshed => 1});
$bug = OpenQA::Schema::Result::Bugs->get_bug('poo#200', $t->app->db);
ok($bug->refreshed, 'bug refreshed');
ok($bug->bugid,     'bugid matched');



done_testing();
