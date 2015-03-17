#<<< do not let perltidy touch this
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
        variables => '',
        settings => [{ key => "DESKTOP", value => "textmode" },{ key => "VIDEOMODE", value => "text" },],
    },

    TestSuites => {
        id => 1002,
        name => "kde",
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" }],
    },

    TestSuites => {
        id => 1013,
        name => "RAID0",
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 0 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },

    TestSuites => {
        id => 1014,
        name => "client1",
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" }, { key => "PARALLEL_WITH", value => "server" }],
    },

    TestSuites => {
        id => 1015,
        name => "server",
        variables => '',
        settings => [{ key => "DESKTOP", value => "textmode" }],
    },

    TestSuites => {
        id => 1016,
        name => "client2",
        variables => '',
        settings => [{ key => "DESKTOP", value => "textmode" }, { key => "PARALLEL_WITH", value => "server" }],
    },

    TestSuites => {
        id => 1017,
        name => "advanced_kde",
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" }, { key => "START_AFTER_TEST", value => "kde,textmode" }],
    },
    JobGroups => {
        id => 1001,
	name => 'opensuse'
    },

    Products => {
		 name => '',
		 distri => 'opensuse',
		 version => '13.1',
		 flavor => 'DVD',
		 arch => 'i586',
		 variables => '',
		 settings => [
			      { key => "ISO_MAXSIZE",
			        value => 4_700_372_992 },
			      { key => "DVD",
			        value => "1" },
			     ],
		 job_templates => [
				   { machine => { name => '32bit' }, test_suite => { name => 'textmode' }, prio => 40, group_id => 1001 },
				   { machine => { name => '64bit' }, test_suite => { name => 'kde' }, prio => 40, group_id => 1001 },
				   { machine => { name => '32bit' }, test_suite => { name => 'client1' }, prio => 40, group_id => 1001 },
				   { machine => { name => '32bit' }, test_suite => { name => 'client2' }, prio => 40, group_id => 1001 },
				   { machine => { name => '32bit' }, test_suite => { name => 'server' }, prio => 40, group_id => 1001 },
				   { machine => { name => '32bit' }, test_suite => { name => 'advanced_kde' }, prio => 40, group_id => 1001 },
				   { machine => { name => '64bit' }, test_suite => { name => 'client1' }, prio => 40, group_id => 1001 },
				   { machine => { name => '64bit' }, test_suite => { name => 'client2' }, prio => 40, group_id => 1001 },
				   { machine => { name => '64bit' }, test_suite => { name => 'server' }, prio => 40, group_id => 1001 },
				   { machine => { name => '64bit' }, test_suite => { name => 'advanced_kde' }, prio => 40, group_id => 1001 },],
    },
]
#>>>
# vim: set sw=4 et:
