[
    Assets => {
        id        => 1,
        type      => 'iso',
        name      => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
    },
    Assets => {
        id   => 2,
        type => 'iso',
        name => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'
    },
    Assets => {
        id   => 3,
        type => 'iso',
        name => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso'
    },
    Assets => {
        id   => 4,
        type => 'iso',
        name => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso',
    },
    Assets => {
        id   => 5,
        type => 'hdd',
        name => 'openSUSE-13.1-x86_64.hda.xz',
    },
    JobGroups => {
        id   => 1001,
        name => 'opensuse'
    },
    JobGroups => {
        id   => 1002,
        name => 'opensuse test'
    },
    Jobs => {
        id         => 99926,
        group_id   => 1001,
        priority   => 56,
        result     => "incomplete",
        retry_avbl => 3,
        settings   => [{key => 'DESKTOP', value => 'minimalx'}, {key => 'ISO', value => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso'}, {key => 'ISO_MAXSIZE', value => 737280000}, {key => 'ISO_1', value => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso'}],
        ARCH       => 'x86_64',
        BUILD      => '87.5011',
        DISTRI     => 'opensuse',
        FLAVOR     => 'staging_e',
        TEST       => 'minimalx',
        VERSION    => 'Factory',
        MACHINE    => '32bit',
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),    # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        jobs_assets => [{asset_id => 4},]

    },
    Jobs => {
        id         => 99927,
        group_id   => 1001,
        priority   => 45,
        result     => "none",
        state      => "scheduled",
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                                                                                                                              # Two hours ago
        backend    => 'qemu',
        t_finished => undef,
        t_started  => undef,
        TEST       => "RAID0",
        retry_avbl => 3,
        ARCH       => 'i586',
        FLAVOR     => 'DVD',
        DISTRI     => 'opensuse',
        MACHINE    => '32bit',
        BUILD      => '0091',
        VERSION    => '13.1',
        settings   => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'INSTALLONLY', value => '1'}, {key => 'RAIDLEVEL', value => '0'}, {key => 'DVD', value => '1'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'LIVETEST', value => '1'},]
    },
    Jobs => {
        id         => 99928,
        priority   => 46,
        result     => "none",
        state      => "scheduled",
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                                                                                           # Two hours ago
        t_finished => undef,
        t_started  => undef,
        backend    => 'qemu',
        TEST       => "RAID1",
        retry_avbl => 3,
        FLAVOR     => 'DVD',
        BUILD      => '0091',
        DISTRI     => 'opensuse',
        ARCH       => 'i586',
        VERSION    => '13.1',
        MACHINE    => '32bit',
        settings   => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'INSTALLONLY', value => '1'}, {key => 'RAIDLEVEL', value => '1'}, {key => 'DVD', value => '1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'},]
    },
    Jobs => {
        id         => 99937,
        group_id   => 1001,
        priority   => 35,
        result     => "passed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 536400, 'UTC'),    # 149 hours ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 540000, 'UTC'),    # 150 hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),      # Two hours ago
        TEST       => "kde",
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        ARCH        => 'i586',
        VERSION     => '13.1',
        FLAVOR      => 'DVD',
        BUILD       => '0091',
        DISTRI      => 'opensuse',
        MACHINE     => '32bit',
        result_dir  => '00099937-opensuse-13.1-DVD-i586-Build0091-kde',
        settings => [{key => 'DVD', value => '1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'QEMUCPU', value => 'qemu32'}]
    },
    Jobs => {
        id         => 99938,
        group_id   => 1001,
        priority   => 36,
        result     => "failed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),                                                                                                                                                                                     # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                     # Two hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),                                                                                                                                                                                     # One hours ago
        TEST       => "doc",
        ARCH       => 'x86_64',
        VERSION    => 'Factory',
        FLAVOR     => 'DVD',
        BUILD      => '0048',
        DISTRI     => 'opensuse',
        MACHINE    => '64bit',
        backend    => 'qemu',
        retry_avbl => 3,
        result_dir => '00099938-opensuse-Factory-DVD-x86_64-Build0048-doc',
        settings   => [{key => 'DVD', value => '1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso'}, {key => 'QEMUCPU', value => 'qemu64'}]
    },
    Jobs => {
        id         => 99939,
        group_id   => 1001,
        priority   => 36,
        result     => "softfailed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),    # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),    # One hours ago
        TEST       => "kde",
        ARCH       => 'x86_64',
        VERSION    => 'Factory',
        backend    => 'qemu',
        FLAVOR     => 'DVD',
        BUILD      => '0048',
        DISTRI     => 'opensuse',
        MACHINE    => '64bit',
        retry_avbl => 3,
        # no result dir, let us assume that this is an old test that has
        # already be pruned
        settings => [{key => 'DVD', value => '1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso'}, {key => 'QEMUCPU', value => 'qemu64'}, {key => 'HDD_1', value => 'openSUSE-13.1-x86_64.hda'},]
    },
    Jobs => {
        id         => 99940,
        group_id   => 1001,
        priority   => 36,
        result     => "failed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),                                                                                                                                                                                     # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                     # Two hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                     # Two hours ago
        TEST       => "doc",
        ARCH       => 'x86_64',
        VERSION    => 'Factory',
        FLAVOR     => 'DVD',
        BUILD      => '0048@0815',
        DISTRI     => 'opensuse',
        MACHINE    => '64bit',
        backend    => 'qemu',
        retry_avbl => 3,
        result_dir => '00099938-opensuse-Factory-DVD-x86_64-Build0048-doc',
        settings   => [{key => 'DVD', value => '1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso'}, {key => 'QEMUCPU', value => 'qemu64'}]
    },
    Jobs => {
        id         => 99946,
        group_id   => 1001,
        priority   => 35,
        result     => "passed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 10800, 'UTC'),    # Three hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),    # Four hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),     # Two hours ago
        TEST       => "textmode",
        ARCH       => 'i586',
        FLAVOR     => 'DVD',
        DISTRI     => 'opensuse',
        BUILD      => '0091',
        VERSION    => '13.1',
        MACHINE    => '32bit',
        backend    => 'qemu',
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        result_dir  => '00099946-opensuse-13.1-DVD-i586-Build0091-textmode',
        settings => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'DVD', value => '1'}, {key => 'VIDEOMODE', value => 'text'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'DESKTOP', value => 'textmode'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'HDD_1', value => 'openSUSE-13.1-x86_64.hda'},]
    },
    Jobs => {
        id         => 99945,
        group_id   => 1001,
        clone_id   => 99946,
        priority   => 35,
        result     => "passed",
        state      => "done",
        backend    => 'qemu',
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),    # Four hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 18000, 'UTC'),    # Five hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),     # Two hours ago
        TEST       => "textmode",
        FLAVOR     => 'DVD',
        DISTRI     => 'opensuse',
        BUILD      => '0091',
        VERSION    => '13.1',
        MACHINE    => '32bit',
        ARCH       => 'i586',
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        settings => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'DVD', value => '1'}, {key => 'VIDEOMODE', value => 'text'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'DESKTOP', value => 'textmode'}, {key => 'ISO_MAXSIZE', value => '4700372992'}]
    },
    Jobs => {
        id         => 99944,
        group_id   => 1001,
        clone_id   => 99945,
        priority   => 35,
        result     => "softfailed",
        state      => "done",
        backend    => 'qemu',
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),    # Four hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 18000, 'UTC'),    # Five hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),     # Two hours ago
        TEST       => "textmode",
        FLAVOR     => 'DVD',
        DISTRI     => 'opensuse',
        BUILD      => '0091',
        VERSION    => '13.1',
        MACHINE    => '32bit',
        ARCH       => 'i586',
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        settings => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'DVD', value => '1'}, {key => 'VIDEOMODE', value => 'text'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'DESKTOP', value => 'textmode'}, {key => 'ISO_MAXSIZE', value => '4700372992'}]
    },
    Jobs => {
        id         => 99963,
        group_id   => 1001,
        priority   => 35,
        result     => "none",
        state      => "running",
        t_finished => undef,
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),     # 10 minutes ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        TEST       => "kde",
        BUILD      => '0091',
        DISTRI     => 'opensuse',
        FLAVOR     => 'DVD',
        MACHINE    => '64bit',
        VERSION    => '13.1',
        backend    => 'qemu',
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        ARCH        => 'x86_64',
        settings   => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'DVD', value => '1'}],
        result_dir => '00099963-opensuse-13.1-DVD-x86_64-Build0091-kde',
    },
    Jobs => {
        id         => 99962,
        group_id   => 1001,
        clone_id   => 99963,
        priority   => 35,
        result     => "failed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 10800, 'UTC'),    # Three hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),    # Four hours ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),     # Two hours ago
        TEST       => "kde",
        BUILD      => '0091',
        DISTRI     => 'opensuse',
        FLAVOR     => 'DVD',
        MACHINE    => '64bit',
        VERSION    => '13.1',
        backend    => 'qemu',
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        ARCH        => 'x86_64',
        result_dir  => '00099962-opensuse-13.1-DVD-x86_64-Build0091-kde',
        settings => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'DVD', value => '1'},]
    },
    Jobs => {
        id         => 99981,
        group_id   => 1001,
        priority   => 50,
        result     => "none",
        state      => "cancelled",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3000100, 'UTC'),
        t_started  => undef,
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),      # Two hours ago
        TEST       => "RAID0",
        VERSION    => '13.1',
        ARCH       => 'i686',
        FLAVOR     => 'GNOME-Live',
        MACHINE    => '32bit',
        BUILD      => '0091',
        DISTRI     => 'opensuse',
        jobs_assets => [{asset_id => 3},],
        retry_avbl  => 3,
        settings => [{key => 'DESKTOP', value => 'gnome'}, {key => 'ISO_MAXSIZE', value => '999999999'}, {key => 'LIVECD', value => '1'}, {key => 'ISO', value => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso'}, {key => 'RAIDLEVEL', value => '0'}, {key => 'INSTALLONLY', value => '1'}, {key => 'GNOME', value => '1'}, {key => 'QEMUCPU', value => 'qemu32'},]
    },
    Jobs => {
        id         => 99961,
        group_id   => 1002,
        priority   => 35,
        result     => "none",
        state      => "running",
        t_finished => undef,
        backend    => 'qemu',
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),     # 10 minutes ago
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        TEST       => "kde",
        ARCH       => 'x86_64',
        BUILD      => '0091',
        DISTRI     => 'opensuse',
        FLAVOR     => 'NET',
        MACHINE    => '64bit',
        VERSION    => '13.1',
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        settings => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'DVD', value => '1'},]
    },
]
# vim: set sw=4 et:
