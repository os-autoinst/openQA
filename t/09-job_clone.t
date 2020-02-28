#!/usr/bin/env perl
# Copyright (C) 2014-2020
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

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;

OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $rset     = $t->app->schema->resultset("Jobs");
my $minimalx = $rset->find(99926);
my $clones   = $minimalx->duplicate();
my $clone    = $rset->find($clones->{$minimalx->id}->{clone});

isnt($clone->id, $minimalx->id, "is not the same job");
is($clone->TEST,     "minimalx",  "but is the same test");
is($clone->priority, 56,          "with the same priority");
is($minimalx->state, "done",      "original test keeps its state");
is($clone->state,    "scheduled", "the new job is scheduled");

# Second attempt
ok($minimalx->can_be_duplicated, "looks cloneable");
is($minimalx->duplicate, undef, "cannot clone again");

# Reload minimalx from the database
$minimalx->discard_changes;
is($minimalx->clone_id,  $clone->id,    "relationship is set");
is($minimalx->clone->id, $clone->id,    "relationship works");
is($clone->origin->id,   $minimalx->id, "reverse relationship works");

# After reloading minimalx, it doesn't look cloneable anymore
ok(!$minimalx->can_be_duplicated, "doesn't look cloneable after reloading");
is($minimalx->duplicate, undef, "cannot clone after reloading");

# But cloning the clone should be possible after job state change
$clone->state(OpenQA::Jobs::Constants::CANCELLED);
$clones = $clone->duplicate({prio => 35});
my $second = $rset->find($clones->{$clone->id}->{clone});
is($second->TEST,     "minimalx", "same test again");
is($second->priority, 35,         "with adjusted priority");

done_testing();
