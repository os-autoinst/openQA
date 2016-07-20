#!/usr/bin/env perl -w

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

use strict;
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;

OpenQA::Test::Database->new->create();
my $t  = Test::Mojo->new('OpenQA::WebAPI');
my $rs = $t->app->db->resultset("Jobs");

is($rs->latest_build, '0091');
is($rs->latest_build(version => 'Factory', distri => 'opensuse'), '0048@0815');
is($rs->latest_build(version => '13.1',    distri => 'opensuse'), '0091');

my @latest = $t->app->db->resultset("Jobs")->latest_jobs;
my @ids = map { $_->id } @latest;
# These two jobs have later clones in the fixture set, so should not appear
ok(grep(!/^(99962|99945)$/, @ids));
# These are the later clones, they should appear
ok(grep(/^99963$/, @ids));
ok(grep(/^99946$/, @ids));

done_testing();
