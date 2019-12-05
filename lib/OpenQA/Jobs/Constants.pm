package OpenQA::Jobs::Constants;
use Mojo::Base -base;

use Exporter 'import';

# define states
use constant {
    SCHEDULED => 'scheduled',
    ASSIGNED  => 'assigned',  # job has been sent to worker but worker has not acknowledged yet
    SETUP     => 'setup',     # worker prepares execution of backend/isotovideo (e.g. waiting for cache service)
    RUNNING   => 'running',   # backend/isotovideo is running
    UPLOADING => 'uploading', # remaining test results are uploaded after backend/isotovideo has exited
    CANCELLED => 'cancelled', # job was cancelled while still being scheduled
    DONE      => 'done',      # worker reported that the job is no longer running or web UI considers job dead/abandoned
};
use constant STATES => (SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING, DONE, CANCELLED);

# define "meta" states
use constant PENDING_STATES   => (SCHEDULED, ASSIGNED, SETUP,   RUNNING, UPLOADING);
use constant EXECUTION_STATES => (ASSIGNED,  SETUP,    RUNNING, UPLOADING);
use constant PRE_EXECUTION_STATES => (SCHEDULED);        # Assigned belongs to pre execution, but makes no sense for now
use constant FINAL_STATES         => (DONE, CANCELLED);
use constant {
    PRE_EXECUTION => 'pre_execution',
    EXECUTION     => 'execution',
    FINAL         => 'final',
};

# define results for the overall job
use constant {
    NONE       => 'none',
    PASSED     => 'passed',
    SOFTFAILED => 'softfailed',
    FAILED     => 'failed',
    INCOMPLETE => 'incomplete',    # worker died or reported some problem
    SKIPPED =>
      'skipped',    # dependencies failed before starting this job (FIXME: clarify weird overlap with CANCELLED state)
    OBSOLETED => 'obsoleted'
    , # new iso was posted (FIXME: while the job has already been running, right? otherwise the CANCELLED state would have been used?)
    PARALLEL_FAILED    => 'parallel_failed',       # parallel job failed, this job can't continue
    PARALLEL_RESTARTED => 'parallel_restarted',    # parallel job was restarted, this job has to be restarted too
    USER_CANCELLED     => 'user_cancelled',        # cancelled by user via job_cancel
    USER_RESTARTED     => 'user_restarted',        # restarted by user via job_restart
    TIMEOUT_EXCEEDED   => 'timeout_exceeded',      # killed by the worker after MAX_JOB_TIME has been exceeded
};
use constant RESULTS => (NONE, PASSED, SOFTFAILED, FAILED, INCOMPLETE, SKIPPED,
    OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED, TIMEOUT_EXCEEDED
);

# define "meta" results for the overall job
use constant COMPLETE_RESULTS     => (PASSED,     SOFTFAILED, FAILED);
use constant OK_RESULTS           => (PASSED,     SOFTFAILED);
use constant NOT_COMPLETE_RESULTS => (INCOMPLETE, TIMEOUT_EXCEEDED);
use constant ABORTED_RESULTS =>
  (SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);
use constant NOT_OK_RESULTS => (FAILED, NOT_COMPLETE_RESULTS, ABORTED_RESULTS);
use constant {
    COMPLETE     => 'complete',
    NOT_COMPLETE => 'not_complete',
    ABORTED      => 'aborted',
};

# define results for particular job modules
use constant MODULE_RESULTS => (CANCELLED, FAILED, NONE, PASSED, RUNNING, SKIPPED, SOFTFAILED);

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
  TIMEOUT_EXCEEDED
);

# define mapping from any specific job state/result to a meta state/result
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
sub meta_state {
    my ($state) = @_;
    return $META_STATE_MAPPING{$state} // NONE;
}
sub meta_result {
    my ($result) = @_;
    return $META_RESULT_MAPPING{$result} // NONE;
}
