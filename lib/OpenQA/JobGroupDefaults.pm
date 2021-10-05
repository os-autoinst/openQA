# Copyright 2016-2019 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::JobGroupDefaults;

use strict;
use warnings;

use constant {
    SIZE_LIMIT_GB                  => 100,
    KEEP_LOGS_IN_DAYS              => 30,
    KEEP_IMPORTANT_LOGS_IN_DAYS    => 120,
    KEEP_RESULTS_IN_DAYS           => 365,
    KEEP_IMPORTANT_RESULTS_IN_DAYS => 0,
    PRIORITY                       => 50,
    CARRY_OVER_BUGREFS             => 1,
};

1;
