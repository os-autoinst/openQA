#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

is system('script/openqa-audit-stale-users --help'), 0, 'script runs and prints help';

done_testing();
