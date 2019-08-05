#!/usr/bin/env perl -w

# Copyright (C) 2017-2019 SUSE Linux LLC
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

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $bugs   = $schema->resultset('Bugs');
my $c      = $t->app->build_controller;

my $bug = $bugs->get_bug('poo#200');
ok(!defined $bug, 'bug not refreshed');

$bugs->find(1)->update({refreshed => 1, title => 'foo bar < " & ß'});
$bug = $bugs->get_bug('poo#200');
ok($bug->refreshed, 'bug refreshed');
ok($bug->bugid,     'bugid matched');
is($c->bugtitle_for('poo#200', $bug), "Bug referenced: poo#200\nfoo bar < \" & ß", 'bug title not already escaped');

done_testing();
