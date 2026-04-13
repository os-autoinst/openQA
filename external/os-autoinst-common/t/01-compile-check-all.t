# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
# We need :no_end_test here because otherwise it would output a no warnings
# test for each of the modules, but with the same test number
use Test::Warnings qw(:no_end_test :report_warnings);

use Test::Compile;
my $test = Test::Compile->new();
$test->all_files_ok();
$test->done_testing();
