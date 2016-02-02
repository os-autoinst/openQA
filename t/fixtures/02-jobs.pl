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
        settings   => [{key => 'ARCH', value => 'x86_64'}, {key => 'BUILD', value => 87.5011}, {key => 'DESKTOP', value => 'minimalx'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'FLAVOR', value => 'staging_e'}, {key => 'ISO', value => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso'}, {key => 'ISO_MAXSIZE', value => 737280000}, {key => 'NAME', value => '00000322-opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx'}, {key => 'TEST', value => 'minimalx'}, {key => 'VERSION', value => 'Factory'}, {key => 'MACHINE', value => '32bit'}, {key => 'ISO_1', value => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso'}],
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),    # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        test       => "minimalx",
        worker_id  => 0,
        jobs_assets => [{asset_id => 4},]

    },
    Jobs => {
        id         => 99927,
        group_id   => 1001,
        priority   => 45,
        result     => "none",
        state      => "scheduled",
        backend    => 'qemu',
        t_finished => undef,
        t_started  => undef,
        test       => "RAID0",
        worker_id  => 0,
        retry_avbl => 3,
        settings   => [{key => 'FLAVOR', value => 'DVD'}, {key => 'QEMUCPU', value => 'qemu32'}, {key => 'ARCH', value => 'i586'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'INSTALLONLY', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'VERSION', value => '13.1'}, {key => 'RAIDLEVEL', value => '0'}, {key => 'DVD', value => '1'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'TEST', value => 'RAID0'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'MACHINE', value => '32bit'}, {key => 'LIVETEST', value => '1'},]
    },
    Jobs => {
        id         => 99928,
        priority   => 46,
        result     => "none",
        state      => "scheduled",
        t_finished => undef,
        t_started  => undef,
        backend    => 'qemu',
        test       => "RAID1",
        worker_id  => 0,
        retry_avbl => 3,
        settings   => [{key => 'QEMUCPU', value => 'qemu32'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'INSTALLONLY', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'ARCH', value => 'i586'}, {key => 'RAIDLEVEL', value => '1'}, {key => 'DVD', value => '1'}, {key => 'VERSION', value => '13.1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'TEST', value => 'RAID1'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'MACHINE', value => '32bit'},]
    },
    Jobs => {
        id         => 99937,
        group_id   => 1001,
        priority   => 35,
        result     => "passed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 536400, 'UTC'),    # 149 hours ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 540000, 'UTC'),    # 150 hours ago
        test       => "kde",
        worker_id  => 0,
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        result_dir  => '00099937-opensuse-13.1-DVD-i586-Build0091-kde',
        settings => [{key => 'DVD', value => '1'}, {key => 'VERSION', value => '13.1'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'TEST', value => 'kde'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'QEMUCPU', value => 'qemu32'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'BUILD', value => '0091'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'ARCH', value => 'i586'}, {key => 'MACHINE', value => '32bit'},]
    },
    Jobs => {
        id         => 99938,
        group_id   => 1001,
        priority   => 36,
        result     => "failed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),                                                                                                                                                                                                                                                                                                                                                                                                                                                       # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),                                                                                                                                                                                                                                                                                                                                                                                                                                                       # Two hours ago
        test       => "doc",
        backend    => 'qemu',
        worker_id  => 0,
        retry_avbl => 3,
        result_dir => '00099938-opensuse-Factory-DVD-x86_64-Build0048-doc',
        settings   => [{key => 'DVD', value => '1'}, {key => 'VERSION', value => 'Factory'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'TEST', value => 'doc'}, {key => 'ISO', value => 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso'}, {key => 'QEMUCPU', value => 'qemu64'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'BUILD', value => '0048'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'ARCH', value => 'x86_64'}, {key => 'MACHINE', value => '64bit'},]
    },
    Jobs => {
        id         => 99939,
        group_id   => 1001,
        priority   => 36,
        result     => "passed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600, 'UTC'),    # One hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),    # Two hours ago
        test       => "kde",
        backend    => 'qemu',
        worker_id  => 0,
        retry_avbl => 3,
        # no result dir, let us assume that this is an old test that has
        # already be pruned
        settings => [{key => 'DVD', value => '1'}, {key => 'VERSION', value => 'Factory'}, {key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'TEST', value => 'kde'}, {key => 'ISO', value => 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso'}, {key => 'QEMUCPU', value => 'qemu64'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'BUILD', value => '0048'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'ARCH', value => 'x86_64'}, {key => 'MACHINE', value => '64bit'},]
    },
    Jobs => {
        id         => 99946,
        group_id   => 1001,
        priority   => 35,
        result     => "passed",
        state      => "done",
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 10800, 'UTC'),    # Three hour ago
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 14400, 'UTC'),    # Four hours ago
        test       => "textmode",
        worker_id  => 0,
        backend    => 'qemu',
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        result_dir  => '00099946-opensuse-13.1-DVD-i586-Build0091-textmode',
        settings => [{key => 'FLAVOR', value => 'DVD'}, {key => 'QEMUCPU', value => 'qemu32'}, {key => 'ARCH', value => 'i586'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'BUILD', value => '0091'}, {key => 'VERSION', value => '13.1'}, {key => 'DVD', value => '1'}, {key => 'VIDEOMODE', value => 'text'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'TEST', value => 'textmode'}, {key => 'DESKTOP', value => 'textmode'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'MACHINE', value => '32bit'},]
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
        test       => "textmode",
        worker_id  => 0,
        jobs_assets => [{asset_id => 1},],
        retry_avbl  => 3,
        settings => [{key => 'FLAVOR', value => 'DVD'}, {key => 'QEMUCPU', value => 'qemu32'}, {key => 'ARCH', value => 'i586'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'BUILD', value => '0091'}, {key => 'VERSION', value => '13.1'}, {key => 'DVD', value => '1'}, {key => 'VIDEOMODE', value => 'text'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'}, {key => 'TEST', value => 'textmode'}, {key => 'DESKTOP', value => 'textmode'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'MACHINE', value => '32bit'},]
    },
    Jobs => {
        id         => 99963,
        group_id   => 1001,
        priority   => 35,
        result     => "none",
        state      => "running",
        t_finished => undef,
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),    # 10 minutes ago
        test       => "kde",
        worker_id  => 1,
        backend    => 'qemu',
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        settings   => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'TEST', value => 'kde'}, {key => 'VERSION', value => '13.1'}, {key => 'DVD', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'ARCH', value => 'x86_64'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'MACHINE', value => '64bit'},],
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
        test       => "kde",
        backend    => 'qemu',
        worker_id  => 0,
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        settings => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'TEST', value => 'kde'}, {key => 'VERSION', value => '13.1'}, {key => 'DVD', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'ARCH', value => 'x86_64'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'FLAVOR', value => 'DVD'}, {key => 'MACHINE', value => '64bit'},]
    },
    Jobs => {
        id          => 99981,
        group_id    => 1001,
        priority    => 50,
        result      => "none",
        state       => "cancelled",
        t_finished  => undef,
        t_started   => undef,
        test        => "RAID0",
        worker_id   => 0,
        jobs_assets => [{asset_id => 3},],
        retry_avbl  => 3,
        settings    => [{key => 'DESKTOP', value => 'gnome'}, {key => 'ISO_MAXSIZE', value => '999999999'}, {key => 'LIVECD', value => '1'}, {key => 'ISO', value => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso'}, {key => 'TEST', value => 'RAID0'}, {key => 'VERSION', value => '13.1'}, {key => 'RAIDLEVEL', value => '0'}, {key => 'INSTALLONLY', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'ARCH', value => 'i686'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'GNOME', value => '1'}, {key => 'QEMUCPU', value => 'qemu32'}, {key => 'FLAVOR', value => 'GNOME-Live'}, {key => 'MACHINE', value => '32bit'},]
    },
    Jobs => {
        id         => 99961,
        group_id   => 1002,
        priority   => 35,
        result     => "none",
        state      => "running",
        t_finished => undef,
        backend    => 'qemu',
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),    # 10 minutes ago
        test       => "kde",
        worker_id  => 2,
        jobs_assets => [{asset_id => 2},],
        retry_avbl  => 3,
        settings => [{key => 'DESKTOP', value => 'kde'}, {key => 'ISO_MAXSIZE', value => '4700372992'}, {key => 'ISO', value => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso'}, {key => 'TEST', value => 'kde'}, {key => 'VERSION', value => '13.1'}, {key => 'DVD', value => '1'}, {key => 'BUILD', value => '0091'}, {key => 'ARCH', value => 'x86_64'}, {key => 'DISTRI', value => 'opensuse'}, {key => 'FLAVOR', value => 'NET'}, {key => 'MACHINE', value => '64bit'},]
    },
]
# vim: set sw=4 et:
