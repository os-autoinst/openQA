#!/usr/bin/env perl
# Copyright (C) 2020 SUSE LLC
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
use Test::Warnings;

my @debug = qx{ls -l ../os-autoinst 2>&1};
diag @debug;
my $make = "make update-deps";
my @out  = qx{$make 2>&1};
my $rc   = $?;
diag "rc=$rc";
if ($rc) {
    diag @out;
    BAIL_OUT "Could not run $make: rc=$rc";
}

my @status = grep { not m/^\?/ } qx{git status --porcelain};

ok(!@status, "No changed files after '$make'")
  or diag @status;

done_testing;

