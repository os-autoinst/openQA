use strict;
use warnings;

[
    # parallel dependency for running test
    JobDependencies => {
        parent_job_id => 99961,
        child_job_id => 99963,
        dependency => 2
    },

    # chained dep, done tests
    JobDependencies => {
        parent_job_id => 99937,
        child_job_id => 99938,
        dependency => 1
    },
]
