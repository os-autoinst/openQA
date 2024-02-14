# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
# We need :no_end_test here because otherwise it would output a no warnings
# test for each of the modules, but with the same test number
use Test::Warnings qw(:no_end_test :report_warnings);
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Test::TimeLimit '400';

use Test::Strict;

push @Test::Strict::MODULES_ENABLING_STRICT, 'Test::Most';
push @Test::Strict::MODULES_ENABLING_WARNINGS, 'Test::Most';

$Test::Strict::TEST_SYNTAX = 1;
$Test::Strict::TEST_STRICT = 1;
$Test::Strict::TEST_WARNINGS = 1;
all_perl_files_ok(qw(lib tools xt));
