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

our @EXPORT_OK = qw(
  WEBSOCKET_API_VERSION
  WORKERS_CHECKER_THRESHOLD
  MAX_TIMER
  MIN_TIMER
);


1;
