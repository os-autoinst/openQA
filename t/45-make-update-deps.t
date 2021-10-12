#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings;
# no OpenQA::Test::TimeLimit for this trivial test

my $make = "make update-deps";
my @out = qx{$make};
my $rc = $?;
die "Could not run $make: rc=$rc" if $rc;

my @status = grep { not m/^\?/ } qx{git status --porcelain};

ok(!@status, "No changed files after '$make'")
  or diag @status;

done_testing;

