# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobDependencies::Constants;
use Mojo::Base -base, -signatures;

# Use integers instead of a string labels for DEPENDENCIES because:
#  - It's part of the primary key
#  - JobDependencies is an internal table, not exposed in the API
use constant CHAINED => 1;
use constant PARALLEL => 2;
use constant DIRECTLY_CHAINED => 3;

use constant DEPENDENCIES => (CHAINED, PARALLEL, DIRECTLY_CHAINED);
use constant CHAINED_DEPENDENCIES => (CHAINED, DIRECTLY_CHAINED);

my %DEPENDENCY_DISPLAY_NAMES = (
    CHAINED, => 'Chained',
    PARALLEL, => 'Parallel',
    DIRECTLY_CHAINED, => 'Directly chained',
);

sub display_names () { return values %DEPENDENCY_DISPLAY_NAMES }

sub display_name ($dependency_type) { return $DEPENDENCY_DISPLAY_NAMES{$dependency_type} }

my %DEPENDENCY_JOB_INFO_TYPE_NAME = (
    CHAINED, => 'chained',
    PARALLEL, => 'parallel',
    DIRECTLY_CHAINED, => 'directly_chained',
);

sub names () { return values %DEPENDENCY_JOB_INFO_TYPE_NAME }

sub name ($dependency_type) { return $DEPENDENCY_JOB_INFO_TYPE_NAME{$dependency_type} }

sub job_info_relation ($relation, $dependency_type) {
    return "$DEPENDENCY_JOB_INFO_TYPE_NAME{$dependency_type}_$relation";
}

1;
