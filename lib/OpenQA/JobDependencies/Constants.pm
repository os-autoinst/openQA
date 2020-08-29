# Copyright (C) 2020 SUSE LLC
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

package OpenQA::JobDependencies::Constants;
use Mojo::Base -base;

# Use integers instead of a string labels for DEPENDENCIES because:
#  - It's part of the primary key
#  - JobDependencies is an internal table, not exposed in the API
use constant CHAINED          => 1;
use constant PARALLEL         => 2;
use constant DIRECTLY_CHAINED => 3;

use constant DEPENDENCIES => (CHAINED, PARALLEL, DIRECTLY_CHAINED);
use constant CHAINED_DEPENDENCIES => (CHAINED, DIRECTLY_CHAINED);

my %DEPENDENCY_DISPLAY_NAMES = (
    CHAINED,          => 'Chained',
    PARALLEL,         => 'Parallel',
    DIRECTLY_CHAINED, => 'Directly chained',
);

sub display_names {
    return values %DEPENDENCY_DISPLAY_NAMES;
}

sub display_name {
    my ($dependency_type) = @_;
    return $DEPENDENCY_DISPLAY_NAMES{$dependency_type};
}

my %DEPENDENCY_JOB_INFO_TYPE_NAME = (
    CHAINED,          => 'chained',
    PARALLEL,         => 'parallel',
    DIRECTLY_CHAINED, => 'directly_chained',
);

sub names {
    return values %DEPENDENCY_JOB_INFO_TYPE_NAME;
}

sub name {
    my ($dependency_type) = @_;
    return $DEPENDENCY_JOB_INFO_TYPE_NAME{$dependency_type};
}

sub job_info_relation {
    my ($relation, $dependency_type) = @_;
    return "$DEPENDENCY_JOB_INFO_TYPE_NAME{$dependency_type}_$relation";
}

1;
