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

OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA');

my $minimalx = $t->app->db->resultset("Jobs")->find({id => 99926});
my $clone = $minimalx->duplicate;

isnt($clone->id, $minimalx->id, "is not the same job");
is($clone->test, "minimalx", "but is the same test");
is($clone->priority, 56, "with the same priority");
is($clone->retry_avbl, 3, "with the same retry_avbl");
is($minimalx->state, "done", "original test keeps its state");
is($clone->state, "scheduled", "the new job is scheduled");

# Second attempt
ok($minimalx->can_be_duplicated, "looks cloneable");
is($minimalx->duplicate, undef, "cannot clone again");

# Reload minimalx from the database
$minimalx->discard_changes;
is($minimalx->clone_id, $clone->id, "relationship is set");
is($minimalx->clone->id, $clone->id, "relationship works");
is($clone->origin->id, $minimalx->id, "reverse relationship works");

# Let's check the job_settings (sorry for Perl's antipatterns)
my @m_settings = $minimalx->settings;
my $m_hashed = {};
for my $i (@m_settings) {
    $m_hashed->{$i->key} = $i->value unless $i->key eq "NAME";
}
my @c_settings = $clone->settings;
my $c_hashed = {};
for my $i (@c_settings) {
    $c_hashed->{$i->key} = $i->value;
}
is_deeply($m_hashed, $c_hashed, "equivalent job settings (skipping NAME)");

# After reloading minimalx, it doesn't look cloneable anymore
ok(!$minimalx->can_be_duplicated, "doesn't look cloneable after reloading");
is($minimalx->duplicate, undef, "cannot clone after reloading");

# But cloning the clone should be possible
my $second = $clone->duplicate({prio => 35, retry_avbl => 2});
is($second->test, "minimalx", "same test again");
is($second->priority, 35, "with adjusted priority");
is($second->retry_avbl, 2, "with adjusted retry_avbl");

done_testing();
