[
    Machines => {
        id => 1001,
        name => '32bit',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu32" },],
    },
    Machines => {
        id => 1002,
        name => '64bit',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu64" },],
    },
    Machines => {
        id => 1008,
        name => 'Laptop_64',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu64" },{ key => "LAPTOP", value => "1" },],
    },

    TestSuites => {
        id => 1001,
        name => "textmode",
        prio => 40,
        variables => '',
        settings => [{ key => "DESKTOP", value => "textmode" },{ key => "VIDEOMODE", value => "text" },],
    },

    TestSuites => {
        id => 1002,
        name => "kde",
        prio => 40,
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" }],
    },

    TestSuites => {
        id => 1013,
        name => "RAID0",
        prio => 50,
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 0 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },

    Products => {
        name => '',
        distri => 'opensuse',
        version => '13.1',
        flavor => 'DVD',
        arch => 'i586',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => 4_700_372_992 },{ key => "DVD", value => "1" },],
        job_templates => [{machine => { name => '32bit' }, test_suite => { name => 'textmode' }},{machine => { name => '64bit' }, test_suite => { name => 'kde' }},]
    },
]
# vim: set sw=4 et:
