[
    Workers => {
        id => 1,
        host => 'localhost',
        instance => 1,
        backend => 'qemu',
        properties => [{key => 'JOBTOKEN', value => 'token99963'}],
    },
    Workers => {
        id => 2,
        host => 'remotehost',
        instance => 1,
        backend => 'qemu',
        properties => [{key => 'JOBTOKEN', value => 'token99961'}],
    }
]
# vim: set sw=4 et:
