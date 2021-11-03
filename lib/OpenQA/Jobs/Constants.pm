# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Jobs::Constants;
use Mojo::Base -base, -signatures;

use Exporter 'import';

# job states
use constant {
    # initial job state; the job is supposed to be assigned to a worker by the scheduler
    SCHEDULED => 'scheduled',
    # the job has been sent to worker but worker has not acknowledged yet; the state might be reverted to
    # SCHEDULED in some conditions
    ASSIGNED => 'assigned',
    # worker prepares execution of backend/isotovideo (e.g. waiting for cache service)
    SETUP => 'setup',
    # backend/isotovideo is running
    RUNNING => 'running',
    # remaining test results are uploaded after backend/isotovideo has exited
    UPLOADING => 'uploading',
    # job was cancelled by the user (result USER_CANCELLED is set) or obsoleted due to a new build (result
    # OBSOLETED is set) or skipped due to failed (directly) chained dependencies (result SKIPPED is set)
    CANCELLED => 'cancelled',
    # worker reported that the job is no longer running (a result other than NONE but *including*
    # USER_CANCELLED and OBSOLETED is set) or web UI considers job dead/abandoned (result INCOMPLETE is set)
    # or the job has been cancelled due to failed parallel dependencies (result PARALLEL_FAILED is set)
    DONE => 'done',
};
use constant STATES => (SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING, DONE, CANCELLED);

# note regarding CANCELLED vs. DONE:
# There is an overlap between CANCELLED and DONE (considering that some results are possibly assigned in either of these
# states). The state CANCELLED is set by the web UI side, e.g. instantly after the user clicks on the 'Cancel job' button.
# If the worker acknowledges that the job is cancelled the state is set to DONE. The same applies generally to the other
# overlapping results. Of course if a job has never been picked up by a worker the state is supposed to remain CANCELLED.
# That is usually the case for jobs SKIPPED due to failed chained dependencies (*not* directly chained dependencies).

# "meta" states
use constant PENDING_STATES => (SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING);
use constant EXECUTION_STATES => (ASSIGNED, SETUP, RUNNING, UPLOADING);
use constant PRE_EXECUTION_STATES => (SCHEDULED);
use constant PRISTINE_STATES => (SCHEDULED, ASSIGNED);    # no worker reported any updates/results so far
use constant FINAL_STATES => (DONE, CANCELLED);
use constant {
    PRE_EXECUTION => 'pre_execution',
    EXECUTION => 'execution',
    FINAL => 'final',
};

# results for the overall job
use constant {
    NONE => 'none',    # there's no overall result yet (job is not yet in one of the FINAL_STATES)
    PASSED => 'passed',    # the test has been concluded suggessfully with a positive result
    SOFTFAILED => 'softfailed',    # the test has been concluded suggessfully with a positive result
    FAILED => 'failed',    # the test has been concluded suggessfully with a negative result
    INCOMPLETE => 'incomplete',    # worker died or reported some problem
    SKIPPED => 'skipped',    # (directly) chained dependencies failed before starting this job
    OBSOLETED => 'obsoleted',    # new iso was posted so the job has been cancelled by openQA
    PARALLEL_FAILED => 'parallel_failed',    # parallel job failed, this job can't continue
    PARALLEL_RESTARTED => 'parallel_restarted',    # parallel job was restarted, this job has to be restarted too
    USER_CANCELLED => 'user_cancelled',    # cancelled by user via job_cancel
    USER_RESTARTED => 'user_restarted',    # restarted by user via job_restart
    TIMEOUT_EXCEEDED => 'timeout_exceeded',    # killed by the worker after MAX_JOB_TIME has been exceeded
};
use constant RESULTS => (
    NONE, PASSED, SOFTFAILED, FAILED, INCOMPLETE, SKIPPED,
    OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED, TIMEOUT_EXCEEDED
);

# note: See the "Jobs" section of "GettingStarted.asciidoc" for the difference between SOFTFAILED and FAILED and
#       further details.

# "meta" results for the overall job
use constant COMPLETE_RESULTS => (PASSED, SOFTFAILED, FAILED);
use constant OK_RESULTS => (PASSED, SOFTFAILED);
use constant NOT_COMPLETE_RESULTS => (INCOMPLETE, TIMEOUT_EXCEEDED);
use constant ABORTED_RESULTS =>
  (SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);
use constant NOT_OK_RESULTS => (FAILED, NOT_COMPLETE_RESULTS, ABORTED_RESULTS);
use constant {
    COMPLETE => 'complete',
    NOT_COMPLETE => 'not_complete',
    ABORTED => 'aborted',
};

# results for particular job modules
use constant MODULE_RESULTS => (CANCELLED, FAILED, NONE, PASSED, RUNNING, SKIPPED, SOFTFAILED);

# common result files to be expected in all jobs
use constant COMMON_RESULT_FILES => ('vars.json', 'autoinst-log.txt', 'worker-log.txt', 'worker_packages.txt');

our @EXPORT = qw(
  ASSIGNED
  CANCELLED
  COMPLETE_RESULTS
  DONE
  EXECUTION_STATES
  FAILED
  FINAL_STATES
  INCOMPLETE
  NOT_COMPLETE_RESULTS
  ABORTED
  ABORTED_RESULTS
  NONE
  NOT_OK_RESULTS
  OBSOLETED
  OK_RESULTS
  PARALLEL_FAILED
  PARALLEL_RESTARTED
  PASSED
  PENDING_STATES
  PRE_EXECUTION_STATES
  PRISTINE_STATES
  RESULTS
  RUNNING
  SCHEDULED
  SETUP
  SKIPPED
  SOFTFAILED
  STATES
  UPLOADING
  USER_CANCELLED
  USER_RESTARTED
  MODULE_RESULTS
  COMMON_RESULT_FILES
  TIMEOUT_EXCEEDED
);

# mapping from any specific job state/result to a meta state/result
my %META_STATE_MAPPING = (
    (map { $_ => PRE_EXECUTION } PRE_EXECUTION_STATES),
    (map { $_ => EXECUTION } EXECUTION_STATES),
    (map { $_ => FINAL } FINAL_STATES),
);
my %META_RESULT_MAPPING = (
    (map { $_ => $_ } COMPLETE_RESULTS),
    (map { $_ => NOT_COMPLETE } NOT_COMPLETE_RESULTS),
    (map { $_ => ABORTED } ABORTED_RESULTS),
);
sub meta_state ($state) { $META_STATE_MAPPING{$state} // NONE }
sub meta_result ($result) { $META_RESULT_MAPPING{$result} // NONE }
