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

package OpenQA::Constants;

use strict;
use warnings;

use Exporter 'import';

# Minimal worker version that allows them to connect;
# To be modified manuallly when we want to break compability and force workers to update
# If this value differs from server to worker then it won't be able to connect.
use constant WEBSOCKET_API_VERSION => 1;

# Time threshold used to check active workers (in seconds)
use constant WORKERS_CHECKER_THRESHOLD => (2 * 24 * 60 * 60);

# Time verification to be use with WORKERS_CHECKER_THRESHOLD.
# It shouldn't be bigger than WORKERS_CHECKER_THRESHOLD
use constant MAX_TIMER => 100;

# Time verification to be use with WORKERS_CHECKER_THRESHOLD.
use constant MIN_TIMER => 20;

# The max. time a job is allowed to run by default before the worker kills it.
use constant DEFAULT_MAX_JOB_TIME => 7200;

# The smallest time difference of database timestamps we usually distinguish in seconds
# note: PostgreSQL actually provides a higher accuracy for the timestamp type. However,
#       the automatic timestamp handling provided by DBIx only stores whole seconds. The
#       openQA code itself only deals with whole seconds as well.
use constant DB_TIMESTAMP_ACCURACY => 1;

# Define constants related to the video file
# note: All artefacts starting with VIDEO_FILE_NAME_START are considered videos.
use constant VIDEO_FILE_NAME_START => 'video.';
use constant VIDEO_FILE_NAME_REGEX => qr/^.*\/video\.[^\/]*$/;

our @EXPORT_OK = qw(
  WEBSOCKET_API_VERSION
  WORKERS_CHECKER_THRESHOLD
  MAX_TIMER
  MIN_TIMER
  DEFAULT_MAX_JOB_TIME
  DB_TIMESTAMP_ACCURACY
  VIDEO_FILE_NAME_START
  VIDEO_FILE_NAME_REGEX
);

1;
