#!/usr/bin/env perl -w

# Copyright (C) 2019 SUSE LLC
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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler::Scheduler 'offset_from_prio';
use Test::More;
use Test::Warnings;

is(offset_from_prio(50),  1,   'default offset is 1');
is(offset_from_prio(100), 0.1, 'low prio jobs get little offset');
is(offset_from_prio(0),   10,  'high prio jobs get big offset');

is(offset_from_prio(25), 5.5, 'rounded value for 25');
is(offset_from_prio(75), 0.5, 'rounded value for 75');

is(offset_from_prio(300),  0.1, 'capped at 0.1');
is(offset_from_prio(-300), 10,  'capped at 10');

done_testing();
