#!/usr/bin/env perl
# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings;
use FindBin '$Bin';

if (not -e "$Bin/../.git") {
    pass("Skipping all tests, not in a git repository");
    done_testing;
    exit;
}

my $build_dir = $ENV{OS_AUTOINST_BUILD_DIRECTORY} || "$Bin/..";
my $make_tool = $ENV{OS_AUTOINST_MAKE_TOOL} || 'make';
my $make_cmd = "$make_tool update-deps";

chdir $build_dir;
my @out = qx{$make_cmd};
my $rc = $?;
die "Could not run $make_cmd: rc=$rc, out: @out" if $rc;

my @status = grep { not m/^\?/ } qx{git -C "$Bin/.." status --porcelain};
ok(!@status, "No changed files after '$make_cmd'") or diag @status;

done_testing;

