[
    JobModules => {
        script   => 'tests/installation/isosize.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'isosize',
        result   => 'passed',
    },
    JobModules => {
        id       => 2,
        script   => 'tests/installation/bootloader.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'bootloader',
        result   => 'passed',
    },
    JobModules => {
        id        => 3,
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 10000, 'UTC'),
        script    => 'tests/installation/welcome.pm',
        job_id    => 99937,
        category  => 'installation',
        name      => 'welcome',
        result    => 'passed',
    },
    JobModules => {
        id       => 4,
        script   => 'tests/installation/installation_mode.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'installation_mode',
        result   => 'passed',
    },
    JobModules => {
        id           => 5,
        script       => 'tests/installation/installation_mode.pm',
        job_id       => 99939,
        category     => 'installation',
        name         => 'installation_mode',
        result       => 'passed',
        soft_failure => 1,
    },
    JobModules => {
        id       => 6,
        script   => 'tests/installation/installer_timezone.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'installer_timezone',
        result   => 'passed',
    },
    JobModules => {
        id       => 7,
        script   => 'tests/installation/logpackages.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'logpackages',
        result   => 'passed',
    },
    JobModules => {
        id       => 8,
        script   => 'tests/installation/installer_desktopselection.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'installer_desktopselection',
        result   => 'passed',
    },
    JobModules => {
        id        => 9,
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 50000, 'UTC'),
        script    => 'tests/installation/partitioning.pm',
        job_id    => 99937,
        category  => 'installation',
        name      => 'partitioning',
        result    => 'passed',
    },
    JobModules => {
        id        => 10,
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 100000, 'UTC'),

        script   => 'tests/installation/partitioning_finish.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'partitioning_finish',
        result   => 'passed',
    },
    JobModules => {
        id       => 11,
        script   => 'tests/installation/user_settings.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'user_settings',
        result   => 'passed',
    },
    JobModules => {
        id       => 12,
        script   => 'tests/installation/installation_overview.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'installation_overview',
        result   => 'passed',
    },
    JobModules => {
        id       => 13,
        script   => 'tests/installation/start_install.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'start_install',
        result   => 'passed',
    },
    JobModules => {
        id       => 14,
        script   => 'tests/installation/livecdreboot.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'livecdreboot',
        result   => 'passed',
    },
    JobModules => {
        id       => 15,
        script   => 'tests/installation/second_stage.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'second_stage',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/BNC847880_QT_cirrus.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'BNC847880_QT_cirrus',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/reboot_after_install.pm',
        job_id   => 99937,
        category => 'installation',
        name     => 'reboot_after_install',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/consoletest_setup.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'consoletest_setup',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/remove_cd_repo.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'remove_cd_repo',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_lan.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'yast2_lan',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/aplay.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'aplay',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/glibc_i686.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'glibc_i686',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/zypper_up.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'zypper_up',
        result   => 'failed',
    },
    JobModules => {
        script   => 'tests/console/zypper_in.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'zypper_in',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_i.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'yast2_i',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_bootloader.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'yast2_bootloader',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/sshd.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'sshd',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/sshfs.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'sshfs',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/mtab.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'mtab',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/textinfo.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'textinfo',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/consoletest_finish.pm',
        job_id   => 99937,
        category => 'console',
        name     => 'consoletest_finish',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/xterm.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'xterm',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/sshxterm.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'sshxterm',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/kate.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'kate',
        result   => 'failed',
    },
    JobModules => {
        script   => 'tests/x11/firefox.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'firefox',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/firefox_audio.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'firefox_audio',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/ooffice.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'ooffice',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/oomath.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'oomath',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/oocalc.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'oocalc',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/khelpcenter.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'khelpcenter',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/systemsettings.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'systemsettings',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/yast2_users.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'yast2_users',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/dolphin.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'dolphin',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/amarok.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'amarok',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/kontact.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'kontact',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/reboot.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'reboot',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/desktop_mainmenu.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'desktop_mainmenu',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/gimp.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'gimp',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/inkscape.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'inkscape',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/gnucash.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'gnucash',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/x11/shutdown.pm',
        job_id   => 99937,
        category => 'x11',
        name     => 'shutdown',
        result   => 'failed',
    },
    JobModules => {
        script   => 'tests/installation/isosize.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'isosize',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/bootloader.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'bootloader',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/welcome.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'welcome',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installation_mode.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'installation_mode',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'partitioning',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning_finish.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'partitioning_finish',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installer_timezone.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'installer_timezone',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/logpackages.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'logpackages',
        result   => 'failed',
    },
    JobModules => {
        script   => 'tests/installation/installer_desktopselection.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'installer_desktopselection',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/user_settings.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'user_settings',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/installation_overview.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'installation_overview',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/start_install.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'start_install',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/livecdreboot.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'livecdreboot',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/second_stage.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'second_stage',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/BNC847880_QT_cirrus.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'BNC847880_QT_cirrus',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/reboot_after_install.pm',
        job_id   => 99938,
        category => 'installation',
        name     => 'reboot_after_install',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/consoletest_setup.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'consoletest_setup',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/remove_cd_repo.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'remove_cd_repo',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/yast2_lan.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'yast2_lan',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/aplay.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'aplay',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/glibc_i686.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'glibc_i686',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/zypper_up.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'zypper_up',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/zypper_in.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'zypper_in',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/yast2_i.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'yast2_i',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/yast2_bootloader.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'yast2_bootloader',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/sshd.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'sshd',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/sshfs.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'sshfs',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/mtab.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'mtab',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/textinfo.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'textinfo',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/consoletest_finish.pm',
        job_id   => 99938,
        category => 'console',
        name     => 'consoletest_finish',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/xterm.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'xterm',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/sshxterm.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'sshxterm',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/kate.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'kate',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/firefox.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'firefox',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/firefox_audio.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'firefox_audio',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/ooffice.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'ooffice',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/oomath.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'oomath',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/oocalc.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'oocalc',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/khelpcenter.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'khelpcenter',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/systemsettings.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'systemsettings',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/yast2_users.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'yast2_users',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/dolphin.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'dolphin',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/amarok.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'amarok',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/kontact.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'kontact',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/reboot.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'reboot',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/desktop_mainmenu.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'desktop_mainmenu',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/gimp.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'gimp',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/inkscape.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'inkscape',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/gnucash.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'gnucash',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/shutdown.pm',
        job_id   => 99938,
        category => 'x11',
        name     => 'shutdown',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/installation/isosize.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'isosize',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/bootloader.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'bootloader',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/welcome.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'welcome',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installation_mode.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'installation_mode',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installer_timezone.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'installer_timezone',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/logpackages.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'logpackages',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installer_desktopselection.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'installer_desktopselection',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'partitioning',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning_finish.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'partitioning_finish',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/user_settings.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'user_settings',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installation_overview.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'installation_overview',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/start_install.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'start_install',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/livecdreboot.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'livecdreboot',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/second_stage.pm',
        job_id   => 99946,
        category => 'installation',
        name     => 'second_stage',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/consoletest_setup.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'consoletest_setup',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/remove_cd_repo.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'remove_cd_repo',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_lan.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'yast2_lan',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/aplay.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'aplay',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/glibc_i686.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'glibc_i686',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/zypper_up.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'zypper_up',
        result   => 'failed',
    },
    JobModules => {
        script   => 'tests/console/zypper_in.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'zypper_in',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_i.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'yast2_i',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_bootloader.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'yast2_bootloader',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/sshd.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'sshd',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/sshfs.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'sshfs',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/mtab.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'mtab',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/http_srv.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'http_srv',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/mysql_srv.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'mysql_srv',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/textinfo.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'textinfo',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/consoletest_finish.pm',
        job_id   => 99946,
        category => 'console',
        name     => 'consoletest_finish',
        result   => 'passed',
    },
    JobModules => {
        script       => 'tests/console/consoletest_finish.pm',
        job_id       => 99944,
        category     => 'console',
        name         => 'consoletest_finish',
        result       => 'passed',
        soft_failure => 1,
    },
    JobModules => {
        script   => 'tests/installation/isosize.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'isosize',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/bootloader.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'bootloader',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/welcome.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'welcome',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installation_mode.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'installation_mode',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installer_timezone.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'installer_timezone',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/logpackages.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'logpackages',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installer_desktopselection.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'installer_desktopselection',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'partitioning',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/partitioning_finish.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'partitioning_finish',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/user_settings.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'user_settings',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/installation_overview.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'installation_overview',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/start_install.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'start_install',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/livecdreboot.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'livecdreboot',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/second_stage.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'second_stage',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/BNC847880_QT_cirrus.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'BNC847880_QT_cirrus',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/installation/reboot_after_install.pm',
        job_id   => 99963,
        category => 'installation',
        name     => 'reboot_after_install',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/consoletest_setup.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'consoletest_setup',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/remove_cd_repo.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'remove_cd_repo',
        result   => 'passed',
    },
    JobModules => {
        script   => 'tests/console/yast2_lan.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'yast2_lan',
        result   => 'passed',
    },
    JobModules => {
        script    => 'tests/console/aplay.pm',
        job_id    => 99963,
        category  => 'console',
        important => 1,
        name      => 'aplay',
        result    => 'failed',
    },
    JobModules => {
        script   => 'tests/console/glibc_i686.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'glibc_i686',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/zypper_up.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'zypper_up',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/zypper_in.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'zypper_in',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/yast2_i.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'yast2_i',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/yast2_bootloader.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'yast2_bootloader',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/sshd.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'sshd',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/sshfs.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'sshfs',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/mtab.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'mtab',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/textinfo.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'textinfo',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/console/consoletest_finish.pm',
        job_id   => 99963,
        category => 'console',
        name     => 'consoletest_finish',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/xterm.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'xterm',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/sshxterm.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'sshxterm',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/kate.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'kate',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/firefox.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'firefox',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/firefox_audio.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'firefox_audio',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/ooffice.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'ooffice',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/oomath.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'oomath',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/oocalc.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'oocalc',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/khelpcenter.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'khelpcenter',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/systemsettings.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'systemsettings',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/yast2_users.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'yast2_users',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/dolphin.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'dolphin',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/amarok.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'amarok',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/kontact.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'kontact',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/reboot.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'reboot',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/desktop_mainmenu.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'desktop_mainmenu',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/gimp.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'gimp',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/inkscape.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'inkscape',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/gnucash.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'gnucash',
        result   => 'none',
    },
    JobModules => {
        script   => 'tests/x11/shutdown.pm',
        job_id   => 99963,
        category => 'x11',
        name     => 'shutdown',
        result   => 'none',
    },
    JobModules => {
        script    => 'tests/console/aplay.pm',
        job_id    => 99962,
        category  => 'console',
        important => 1,
        name      => 'aplay',
        result    => 'failed',
    },

]
