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

# Default worker timeout
use constant DEFAULT_WORKER_TIMEOUT => (30 * 60);

# Define worker commands; used to validate and differentiate commands
use constant {
    # stop the current job(s), do *not* upload logs and assets
    WORKER_COMMAND_ABORT => 'abort',
    # stop like WORKER_COMMAND_ABORT, duplicate the job, terminate the worker
    WORKER_COMMAND_QUIT => 'quit',
    # stop the current job(s); upload logs and assets
    WORKER_COMMAND_CANCEL => 'cancel',
    # stop like WORKER_COMMAND_CANCEL, mark the job as obsolete
    WORKER_COMMAND_OBSOLETE => 'obsolete',
    # stop providing the livelog for current job
    WORKER_COMMAND_LIVELOG_STOP => 'livelog_stop',
    # start providing the livelog for current job
    WORKER_COMMAND_LIVELOG_START => 'livelog_start',
    # provide additional status updates for developer mode for current job
    WORKER_COMMAND_DEVELOPER_SESSION_START => 'developer_session_start',
    # start a new job
    WORKER_COMMAND_GRAB_JOB => 'grab_job',
    # start a sequence of new jobs (used to start DIRECTLY_CHAINED jobs)
    WORKER_COMMAND_GRAB_JOBS => 'grab_jobs',
};
use constant WORKER_STOP_COMMANDS =>    # commands stopping the current job; also used as stop reasons
  (WORKER_COMMAND_QUIT, WORKER_COMMAND_ABORT, WORKER_COMMAND_CANCEL, WORKER_COMMAND_OBSOLETE);
use constant WORKER_LIVE_COMMANDS =>    # commands used by "live features"
  (WORKER_COMMAND_LIVELOG_STOP, WORKER_COMMAND_LIVELOG_START, WORKER_COMMAND_DEVELOPER_SESSION_START);
use constant WORKER_API_COMMANDS =>     # commands allowed to send via the rest API
  (WORKER_STOP_COMMANDS, WORKER_LIVE_COMMANDS);
use constant WORKER_COMMANDS =>         # all commands
  (WORKER_STOP_COMMANDS, WORKER_LIVE_COMMANDS, WORKER_COMMAND_GRAB_JOB, WORKER_COMMAND_GRAB_JOBS);

# Define reasons for the worker to stop a job (besides receiving one of the WORKER_STOP_COMMANDS)
use constant {
    WORKER_SR_SETUP_FAILURE => 'setup failure',    # an error happend before/when starting the backend
    WORKER_SR_API_FAILURE   => 'api-failure',      # a critical API error occurred
    WORKER_SR_TIMEOUT       => 'timeout',          # MAX_JOB_TIME was exceeded
    WORKER_SR_BROKEN        => 'worker broken',    # worker setup is generally broken, e.g. cache service not started
    WORKER_SR_DONE          => 'done',             # backend exited normally
    WORKER_SR_DIED          => 'died',             # backend died
};
use constant WORKER_STOP_REASONS => (
    WORKER_STOP_COMMANDS, WORKER_SR_SETUP_FAILURE, WORKER_SR_API_FAILURE, WORKER_SR_TIMEOUT, WORKER_SR_BROKEN,
    WORKER_SR_DONE, WORKER_SR_DIED
);
# note: The stop reason can actually be an arbitrary string. The listed ones are common reasons and reasons
#       with special semantics/behavior, e.g. affecting the upload and result computation. Other reasons are
#       always considered special errors leading to incomplete jobs.

# Time verification to use with the "worker_timeout" configuration.
# It shouldn't be bigger than the "worker_timeout" configuration.
use constant MAX_TIMER => 100;

# Time verification to use with the "worker_timeout" configuration.
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
  WEBSOCKET_API_VERSION DEFAULT_WORKER_TIMEOUT
  WORKER_COMMAND_ABORT WORKER_COMMAND_QUIT WORKER_COMMAND_CANCEL WORKER_COMMAND_OBSOLETE WORKER_COMMAND_LIVELOG_STOP
  WORKER_COMMAND_LIVELOG_START WORKER_COMMAND_DEVELOPER_SESSION_START WORKER_STOP_COMMANDS WORKER_LIVE_COMMANDS WORKER_COMMANDS
  WORKER_SR_SETUP_FAILURE WORKER_SR_API_FAILURE WORKER_SR_TIMEOUT WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_STOP_REASONS
  WORKER_API_COMMANDS WORKER_COMMAND_GRAB_JOB WORKER_COMMAND_GRAB_JOBS WORKER_COMMANDS
  MAX_TIMER MIN_TIMER
  DEFAULT_MAX_JOB_TIME
  DB_TIMESTAMP_ACCURACY
  VIDEO_FILE_NAME_START VIDEO_FILE_NAME_REGEX
);

1;
