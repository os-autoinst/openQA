# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use FindBin '$Bin';
use lib "$Bin/../external/os-autoinst-common/lib/perlcritic";
use Test::Perl::Critic;
all_critic_ok(qw(lib));
