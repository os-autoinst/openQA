package OpenQA::JobDependencies::Constants;
use Mojo::Base -base;

# Use integers instead of a string labels for DEPENDENCIES because:
#  - It's part of the primary key
#  - JobDependencies is an internal table, not exposed in the API
use constant CHAINED      => 1;
use constant PARALLEL     => 2;
use constant DEPENDENCIES => (CHAINED, PARALLEL);

1;
