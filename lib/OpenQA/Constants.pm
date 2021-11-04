# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Constants;

use strict;
use warnings;

use Time::Seconds;
use Exporter 'import';
use Regexp::Common 'URI';

# Minimal worker version that allows them to connect;
# To be modified manuallly when we want to break compatibility and force workers to update
# If this value differs from server to worker then it won't be able to connect.
use constant WEBSOCKET_API_VERSION => 1;

# Default worker timeout
use constant DEFAULT_WORKER_TIMEOUT => 30 * ONE_MINUTE;

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
use constant WORKER_API_COMMANDS =>    # commands allowed to send via the rest API
  (WORKER_STOP_COMMANDS, WORKER_LIVE_COMMANDS);
use constant WORKER_COMMANDS =>    # all commands
  (WORKER_STOP_COMMANDS, WORKER_LIVE_COMMANDS, WORKER_COMMAND_GRAB_JOB, WORKER_COMMAND_GRAB_JOBS);

# Define reasons for the worker to stop a job (besides receiving one of the WORKER_STOP_COMMANDS)
use constant {
    WORKER_SR_SETUP_FAILURE => 'setup failure',    # an error happend before/when starting the backend
    WORKER_SR_API_FAILURE => 'api-failure',    # a critical API error occurred
    WORKER_SR_TIMEOUT => 'timeout',    # MAX_JOB_TIME was exceeded
    WORKER_SR_BROKEN => 'worker broken',    # worker setup is generally broken, e.g. cache service not started
    WORKER_SR_DONE => 'done',    # backend exited normally
    WORKER_SR_DIED => 'died',    # backend died
    WORKER_SR_FINISH_OFF => 'finish-off',    # the worker is supposed to terminate after finishing assigned jobs
};
use constant WORKER_STOP_REASONS => (
    WORKER_STOP_COMMANDS, WORKER_SR_SETUP_FAILURE, WORKER_SR_API_FAILURE, WORKER_SR_TIMEOUT, WORKER_SR_BROKEN,
    WORKER_SR_DONE, WORKER_SR_DIED, WORKER_SR_FINISH_OFF
);
# note: The stop reason can actually be an arbitrary string. The listed ones are common reasons and reasons
#       with special semantics/behavior, e.g. affecting the upload and result computation. Other reasons are
#       always considered special errors leading to incomplete jobs.

# Define error categories used alongside the reasons defined above for finer error handling where needed
use constant {
    WORKER_EC_CACHE_FAILURE => 'cache failure',    # the cache service made problems
    WORKER_EC_ASSET_FAILURE => 'asset failure',   # a problem occurred when handling assets, e.g. an asset was not found
};

# Time verification to use with the "worker_timeout" configuration.
# It shouldn't be bigger than the "worker_timeout" configuration.
use constant MAX_TIMER => 100;

# Time verification to use with the "worker_timeout" configuration.
use constant MIN_TIMER => 20;

# The max. time a job is allowed to run by default before the worker stops it.
use constant DEFAULT_MAX_JOB_TIME => 2 * ONE_HOUR;

# The max. time the job setup (asset caching, test syncing) is allowed to take before the worker stops it.
use constant DEFAULT_MAX_SETUP_TIME => ONE_HOUR;

# The smallest time difference of database timestamps we usually distinguish in seconds
# note: PostgreSQL actually provides a higher accuracy for the timestamp type. However,
#       the automatic timestamp handling provided by DBIx only stores whole seconds. The
#       openQA code itself only deals with whole seconds as well.
use constant DB_TIMESTAMP_ACCURACY => 1;

# Define constants related to the video file
# note: All artefacts starting with VIDEO_FILE_NAME_START are considered videos.
use constant VIDEO_FILE_NAME_START => 'video.';
use constant VIDEO_FILE_NAME_REGEX => qr/^.*\/video\.[^\/]*$/;

use constant FRAGMENT_REGEX => qr'(#([-?/:@.~!$&\'()*+,;=\w]|%[0-9a-fA-F]{2})*)*';

our @EXPORT_OK = qw(
  WEBSOCKET_API_VERSION DEFAULT_WORKER_TIMEOUT
  WORKER_COMMAND_ABORT WORKER_COMMAND_QUIT WORKER_COMMAND_CANCEL WORKER_COMMAND_OBSOLETE WORKER_COMMAND_LIVELOG_STOP
  WORKER_COMMAND_LIVELOG_START WORKER_COMMAND_DEVELOPER_SESSION_START WORKER_STOP_COMMANDS WORKER_LIVE_COMMANDS WORKER_COMMANDS
  WORKER_SR_SETUP_FAILURE WORKER_SR_API_FAILURE WORKER_SR_TIMEOUT WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_SR_FINISH_OFF
  WORKER_STOP_REASONS
  WORKER_EC_CACHE_FAILURE WORKER_EC_ASSET_FAILURE
  WORKER_API_COMMANDS WORKER_COMMAND_GRAB_JOB WORKER_COMMAND_GRAB_JOBS WORKER_COMMANDS
  MAX_TIMER MIN_TIMER
  DEFAULT_MAX_JOB_TIME
  DEFAULT_MAX_SETUP_TIME
  DB_TIMESTAMP_ACCURACY
  VIDEO_FILE_NAME_START VIDEO_FILE_NAME_REGEX
  FRAGMENT_REGEX
);

1;
