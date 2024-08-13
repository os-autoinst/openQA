#!/usr/bin/perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use warnings;
use FindBin '$Bin';
use lib "$Bin/../lib/perlcritic";
use Test::Perl::Critic::Policy qw/ all_policies_ok /;

all_policies_ok();
