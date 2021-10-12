# Copyright 2016-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobGroupDefaults;

use strict;
use warnings;

use constant {
    SIZE_LIMIT_GB => 100,
    KEEP_LOGS_IN_DAYS => 30,
    KEEP_IMPORTANT_LOGS_IN_DAYS => 120,
    KEEP_RESULTS_IN_DAYS => 365,
    KEEP_IMPORTANT_RESULTS_IN_DAYS => 0,
    PRIORITY => 50,
    CARRY_OVER_BUGREFS => 1,
};

1;
