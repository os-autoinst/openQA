# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
# no OpenQA::Test::TimeLimit for this trivial test

use Test::Warnings ':report_warnings';

is(system('script/openqa-label-all --help'), 0);

done_testing();
