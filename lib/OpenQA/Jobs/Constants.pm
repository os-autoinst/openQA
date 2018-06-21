package OpenQA::Jobs::Constants;

use Mojo::Base -base;
our @ISA = qw(Exporter);

# States
use constant {
    SCHEDULED => 'scheduled',
    SETUP     => 'setup',
    RUNNING   => 'running',
    CANCELLED => 'cancelled',
    DONE      => 'done',
    UPLOADING => 'uploading',
    ASSIGNED  => 'assigned'
};

use constant STATES => (SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING, DONE, CANCELLED);
use constant PENDING_STATES => (SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING);
use constant EXECUTION_STATES => (ASSIGNED, SETUP, RUNNING, UPLOADING);
use constant PRE_EXECUTION_STATES => (SCHEDULED);    # Assigned belongs to pre execution, but makes no sense for now
use constant FINAL_STATES => (DONE, CANCELLED);

# Results
use constant {
    NONE               => 'none',
    PASSED             => 'passed',
    SOFTFAILED         => 'softfailed',
    FAILED             => 'failed',
    INCOMPLETE         => 'incomplete',              # worker died or reported some problem
    SKIPPED            => 'skipped',                 # dependencies failed before starting this job
    OBSOLETED          => 'obsoleted',               # new iso was posted
    PARALLEL_FAILED    => 'parallel_failed',         # parallel job failed, this job can't continue
    PARALLEL_RESTARTED => 'parallel_restarted',      # parallel job was restarted, this job has to be restarted too
    USER_CANCELLED     => 'user_cancelled',          # cancelled by user via job_cancel
    USER_RESTARTED     => 'user_restarted',          # restarted by user via job_restart
};
use constant RESULTS => (NONE, PASSED, SOFTFAILED, FAILED, INCOMPLETE, SKIPPED,
    OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED
);
use constant COMPLETE_RESULTS => (PASSED, SOFTFAILED, FAILED);
use constant OK_RESULTS => (PASSED, SOFTFAILED);
use constant INCOMPLETE_RESULTS =>
  (INCOMPLETE, SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);
use constant NOT_OK_RESULTS => (INCOMPLETE_RESULTS, FAILED);

our @EXPORT = qw(
  ASSIGNED
  CANCELLED
  COMPLETE_RESULTS
  DONE
  EXECUTION_STATES
  FAILED
  FINAL_STATES
  INCOMPLETE
  INCOMPLETE_RESULTS
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
);
