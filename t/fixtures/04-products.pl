use strict;
use warnings;

[
    Machines => {
        id => 1001,
        name => '32bit',
        backend => 'qemu',
        settings => [{key => "QEMUCPU", value => "qemu32"},],
    },
    Machines => {
        id => 1002,
        name => '64bit',
        backend => 'qemu',
        settings => [{key => "QEMUCPU", value => "qemu64"},],
    },
    Machines => {
        id => 1008,
        name => 'Laptop_64',
        backend => 'qemu',
        settings => [{key => "QEMUCPU", value => "qemu64"}, {key => "LAPTOP", value => "1"},],
    },

    TestSuites => {
        id => 1001,
        name => "textmode",
        settings => [{key => "DESKTOP", value => "textmode"}, {key => "VIDEOMODE", value => "text"},],
    },

    TestSuites => {
        id => 1002,
        name => "kde",
        description => 'Simple kde test, before advanced_kde',
        settings => [{key => "DESKTOP", value => "kde"}],
    },

    TestSuites => {
        id => 1013,
        name => "RAID0",
        settings =>
          [{key => "RAIDLEVEL", value => 0}, {key => "INSTALLONLY", value => 1}, {key => "DESKTOP", value => "kde"},],
    },

    TestSuites => {
        id => 1014,
        name => "client1",
        settings => [
            {key => "DESKTOP", value => "kde"},
            {key => "PARALLEL_WITH", value => "server"},
            {key => "PRECEDENCE", value => "wontoverride"}
        ],
    },

    TestSuites => {
        id => 1015,
        name => "server",
        settings => [{key => "+PRECEDENCE", value => "overridden"}, {key => "DESKTOP", value => "textmode"}],
    },

    TestSuites => {
        id => 1016,
        name => "client2",
        settings => [{key => "DESKTOP", value => "textmode"}, {key => "PARALLEL_WITH", value => "server"}],
    },

    TestSuites => {
        id => 1017,
        name => "advanced_kde",
        description => 'See kde for simple test',
        settings => [
            {key => "DESKTOP", value => "kde"},
            {key => "START_AFTER_TEST", value => "kde,textmode"},
            {key => "PUBLISH_HDD_1", value => "%DISTRI%-%VERSION%-%ARCH%-%DESKTOP%-%QEMUCPU%.qcow2"}
        ],
    },
    Products => {
        id => 1,
        name => '',
        distri => 'opensuse',
        version => '13.1',
        flavor => 'DVD',
        arch => 'i586',
        settings => [
            {
                key => "ISO_MAXSIZE",
                value => 4_700_372_992
            },
            {
                key => "DVD",
                value => "1"
            },
        ],
        job_templates => [
            {
                machine => {name => '32bit'},
                test_suite => {name => 'textmode'},
                prio => 40,
                group_id => 1001,
                description => '32bit textmode prio 40'
            },
            {machine => {name => '64bit'}, test_suite => {name => 'textmode'}, prio => 40, group_id => 1001},
            {machine => {name => '64bit'}, test_suite => {name => 'kde'}, prio => 40, group_id => 1001},
            {machine => {name => '32bit'}, test_suite => {name => 'client1'}, prio => 40, group_id => 1001},
            {machine => {name => '32bit'}, test_suite => {name => 'client2'}, prio => 40, group_id => 1001},
            {machine => {name => '32bit'}, test_suite => {name => 'server'}, prio => 40, group_id => 1001},
            {machine => {name => '64bit'}, test_suite => {name => 'client1'}, prio => 40, group_id => 1001},
            {machine => {name => '64bit'}, test_suite => {name => 'client2'}, prio => 40, group_id => 1001},
            {machine => {name => '64bit'}, test_suite => {name => 'server'}, prio => 40, group_id => 1001},
            {
                machine => {name => '64bit'},
                test_suite => {name => 'advanced_kde'},
                prio => 40,
                group_id => 1001,
                settings => [{key => 'DESKTOP', value => 'advanced_kde'}, {key => 'ADVANCED', value => '1'},],
            },
        ],
    },
    Products => {
        id => 2,
        name => '',
        distri => 'sle',
        version => '12-SP1',
        flavor => 'Server-DVD-Updates',
        arch => 'x86_64',
    },
    Products => {
        id => 3,
        name => '',
        distri => 'opensuse',
        version => '13.1',
        flavor => 'DVD',
        arch => 'ppc64',
    },
]
