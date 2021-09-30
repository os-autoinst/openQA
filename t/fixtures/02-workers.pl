use strict;
use warnings;

[
    Workers => {
        host => 'localhost',
        instance => 1,
        properties => [{key => 'JOBTOKEN', value => 'token99963'}],
        job_id => 99963,
    },
    Workers => {
        host => 'remotehost',
        instance => 1,
        properties => [{key => 'JOBTOKEN', value => 'token99961'}],
        job_id => 99961,
    }]
