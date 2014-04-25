[
    Machines => {
        id => 1001,
        name => '32bit',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu32'
    },
    Machines => {
        id => 1002,
        name => '64bit',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu64'
    },
    Machines => {
        id => 1003,
        name => 'smp_32',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu32;QEMUCPUS=4;SMP=1'
    },
    Machines => {
        id => 1004,
        name => 'smp_64',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu64;QEMUCPUS=4;SMP=1'
    },
    Machines => {
        id => 1005,
        name => 'USBboot_32',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu32;USBBOOT=1'
    },
    Machines => {
        id => 1006,
        name => 'USBboot_64',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu64;USBBOOT=1'
    },
    Machines => {
        id => 1007,
        name => 'Laptop_32',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu32;LAPTOP=1'
    },
    Machines => {
        id => 1008,
        name => 'Laptop_64',
        backend => 'qemu',
        variables => 'QEMUCPU=qemu64;LAPTOP=1'
    },

    TestSuites => {
        id => 1001,
        name => 'textmode',
        prio => 40,
        variables => 'DESKTOP=textmode;VIDEOMODE=text'
    },
    TestSuites => {
        id => 1002,
        name => 'kde',
        prio => 40,
        variables => 'DESKTOP=kde'
    },
    TestSuites => {
        id => 1003,
        name => 'uefi',
        prio => 45,
        variables => 'UEFI=1;DESKTOP=kde;INSTALLONLY=1'
    },
    TestSuites => {
        id => 1004,
        name => 'kde+btrfs',
        prio => 50,
        variables => 'DESKTOP=kde;BTRFS=1;HDDSIZEGB=20'
    },
    TestSuites => {
        id => 1005,
        name => 'gnome',
        prio => 45,
        variables => 'DESKTOP=gnome'
    },
    TestSuites => {
        id => 1006,
        name => 'gnome+btrfs',
        prio => 50,
        variables => 'DESKTOP=gnome;LVM=1;BTRFS=1;HDDSIZEGB=20'
    },
    TestSuites => {
        id => 1007,
        name => 'minimalx',
        prio => 45,
        variables => 'DESKTOP=minimalx'
    },
    TestSuites => {
        id => 1008,
        name => 'minimalx+btrfs',
        prio => 50,
        variables => 'DESKTOP=minimalx;BTRFS=1;HDDSIZEGB=20'
    },
    TestSuites => {
        id => 1009,
        name => 'minimalx+btrfs+nosephome',
        prio => 50,
        variables => 'DESKTOP=minimalx;BTRFS=1;HDDSIZEGB=20;INSTALLONLY=1;TOGGLEHOME=1'
    },
    TestSuites => {
        id => 1010,
        name => 'textmode+btrfs',
        prio => 50,
        variables => 'DESKTOP=textmode;VIDEOMODE=text;BTRFS=1;HDDSIZEGB=20'
    },
    TestSuites => {
        id => 1011,
        name => 'lxde',
        prio => 49,
        variables => 'DESKTOP=lxde;LVM=1'
    },
    TestSuites => {
        id => 1012,
        name => 'xfce',
        prio => 49,
        variables => 'DESKTOP=xfce'
    },
    TestSuites => {
        id => 1013,
        name => 'RAID0',
        prio => 50,
        variables => 'RAIDLEVEL=0;INSTALLONLY=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1014,
        name => 'RAID1',
        prio => 51,
        variables => 'RAIDLEVEL=1;INSTALLONLY=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1015,
        name => 'RAID5',
        prio => 51,
        variables => 'RAIDLEVEL=5;INSTALLONLY=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1016,
        name => 'RAID10',
        prio => 51,
        variables => 'RAIDLEVEL=10;INSTALLONLY=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1017,
        name => 'btrfscryptlvm',
        prio => 50,
        variables => 'BTRFS=1;HDDSIZEGB=20;ENCRYPT=1;LVM=1;NICEVIDEO=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1018,
        name => 'cryptlvm',
        prio => 50,
        variables => 'REBOOTAFTERINSTALL=0;ENCRYPT=1;LVM=1;NICEVIDEO=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1019,
        name => 'doc',
        prio => 60,
        variables => 'DOCRUN=1;QEMUVGA=std;DESKTOP=kde'
    },
    TestSuites => {
        id => 1020,
        name => 'doc_de',
        prio => 60,
        variables => 'DOCRUN=1;QEMUVGA=std;INSTLANG=de_DE;DESKTOP=kde'
    },
    TestSuites => {
        id => 1021,
        name => 'kde-live',
        prio => 48,
        variables => 'DESKTOP=kde;LIVETEST=1'
    },
    TestSuites => {
        id => 1022,
        name => 'gnome-live',
        prio => 48,
        variables => 'DESKTOP=gnome;LIVETEST=1'
    },
    TestSuites => {
        id => 1023,
        name => 'rescue',
        prio => 49,
        variables => 'DESKTOP=xfce;LIVETEST=1;NOAUTOLOGIN=1;REBOOTAFTERINSTALL=0'
    },
    TestSuites => {
        id => 1024,
        name => 'nice',
        prio => 50,
        variables => 'NICEVIDEO=1;DOCRUN=1;REBOOTAFTERINSTALL=0;SCREENSHOTINTERVAL=0.25;DESKTOP=kde'
    },
    TestSuites => {
        id => 1025,
        name => 'splitusr',
        prio => 50,
        variables => 'NICEVIDEO=1;SPLITUSR=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1026,
        name => 'update_121',
        prio => 50,
        variables => 'UPGRADE=1;HDD_1=openSUSE-12.1-x86_64.hda;HDDVERSION=openSUSE-12.1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1027,
        name => 'update_122',
        prio => 50,
        variables => 'UPGRADE=1;HDD_1=openSUSE-12.2-x86_64.hda;HDDVERSION=openSUSE-12.2;DESKTOP=kde'
    },
    TestSuites => {
        id => 1028,
        name => 'update_123',
        prio => 50,
        variables => 'UPGRADE=1;HDD_1=openSUSE-12.3-x86_64.hda;HDDVERSION=openSUSE-12.3;DESKTOP=kde'
    },
    TestSuites => {
        id => 1029,
        name => 'dual_windows8',
        prio => 50,
        variables => 'HDD_1=Windows-8.hda;HDDVERSION=Windows 8;HDDMODEL=ide-hd;DUALBOOT=1;NUMDISKS=1;DESKTOP=kde'
    },
    TestSuites => {
        id => 1030,
        name => 'install_only',
        prio => 40,
        variables => 'INSTALLONLY=1;DESKTOP=kde'
    },

    Products => {
        name => 'oS-DVD-i586',
        distri => 'opensuse',
        flavor => 'DVD',
        arch => 'i586',
        variables => 'ISO_MAXSIZE=4_700_372_992;DVD=1',
        job_templates => [
            {machine_id => 1001, test_suite_id => 1001},
            {machine_id => 1001, test_suite_id => 1002},
            {machine_id => 1001, test_suite_id => 1004},
            {machine_id => 1001, test_suite_id => 1005},
            {machine_id => 1001, test_suite_id => 1006},
            {machine_id => 1001, test_suite_id => 1007},
            {machine_id => 1001, test_suite_id => 1008},
            {machine_id => 1001, test_suite_id => 1009},
            {machine_id => 1001, test_suite_id => 1010},
            {machine_id => 1001, test_suite_id => 1011},
            {machine_id => 1001, test_suite_id => 1012},
            {machine_id => 1005, test_suite_id => 1002}, # USB+kde
            {machine_id => 1007, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1007, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1001, test_suite_id => 1013},
            {machine_id => 1001, test_suite_id => 1014},
            {machine_id => 1001, test_suite_id => 1015},
            {machine_id => 1001, test_suite_id => 1016},
            {machine_id => 1001, test_suite_id => 1017},
            {machine_id => 1001, test_suite_id => 1018},
            {machine_id => 1003, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1001, test_suite_id => 1026}, #update_121
            {machine_id => 1001, test_suite_id => 1027}, #update_122
            {machine_id => 1001, test_suite_id => 1028}, #update_123
            {machine_id => 1001, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-DVD-x86_64',
        distri => 'opensuse',
        flavor => 'DVD',
        arch => 'x86_64',
        variables => 'ISO_MAXSIZE=4_700_372_992;DVD=1',
        job_templates => [
            {machine_id => 1002, test_suite_id => 1001},
            {machine_id => 1002, test_suite_id => 1002},
            {machine_id => 1002, test_suite_id => 1003},
            {machine_id => 1002, test_suite_id => 1004},
            {machine_id => 1002, test_suite_id => 1005},
            {machine_id => 1002, test_suite_id => 1006},
            {machine_id => 1002, test_suite_id => 1007},
            {machine_id => 1002, test_suite_id => 1008},
            {machine_id => 1002, test_suite_id => 1009},
            {machine_id => 1002, test_suite_id => 1010},
            {machine_id => 1002, test_suite_id => 1011},
            {machine_id => 1002, test_suite_id => 1012},
            {machine_id => 1006, test_suite_id => 1002}, # USB+kde
            {machine_id => 1008, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1008, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1002, test_suite_id => 1013},
            {machine_id => 1002, test_suite_id => 1014},
            {machine_id => 1002, test_suite_id => 1015},
            {machine_id => 1002, test_suite_id => 1016},
            {machine_id => 1002, test_suite_id => 1017},
            {machine_id => 1002, test_suite_id => 1018},
            {machine_id => 1002, test_suite_id => 1019},
            {machine_id => 1002, test_suite_id => 1024},
            {machine_id => 1002, test_suite_id => 1025},
            {machine_id => 1004, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1002, test_suite_id => 1026}, #update_121
            {machine_id => 1002, test_suite_id => 1027}, #update_122
            {machine_id => 1002, test_suite_id => 1028}, #update_123
            {machine_id => 1002, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-GNOME-Live-i686',
        distri => 'opensuse',
        flavor => 'GNOME-Live',
        arch => 'i686',
        variables => 'LIVECD=1;ISO_MAXSIZE=999_999_999;GNOME=1',
        job_templates => [
            {machine_id => 1001, test_suite_id => 1005},
            {machine_id => 1005, test_suite_id => 1005}, # USB+gnome
            {machine_id => 1001, test_suite_id => 1006},
            {machine_id => 1007, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1001, test_suite_id => 1013},
            {machine_id => 1001, test_suite_id => 1014},
            {machine_id => 1001, test_suite_id => 1015},
            {machine_id => 1001, test_suite_id => 1016},
            {machine_id => 1001, test_suite_id => 1017},
            {machine_id => 1001, test_suite_id => 1018},
            {machine_id => 1001, test_suite_id => 1022},
            {machine_id => 1003, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1001, test_suite_id => 1026}, #update_121
            {machine_id => 1001, test_suite_id => 1027}, #update_122
            {machine_id => 1001, test_suite_id => 1028}, #update_123
            {machine_id => 1001, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-GNOME-Live-x86_64',
        distri => 'opensuse',
        flavor => 'GNOME-Live',
        arch => 'x86_64',
        variables => 'LIVECD=1;ISO_MAXSIZE=999_999_999',
        job_templates => [
            {machine_id => 1002, test_suite_id => 1005},
            {machine_id => 1006, test_suite_id => 1005}, # USB+gnome
            {machine_id => 1002, test_suite_id => 1006},
            {machine_id => 1008, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1002, test_suite_id => 1013},
            {machine_id => 1002, test_suite_id => 1014},
            {machine_id => 1002, test_suite_id => 1015},
            {machine_id => 1002, test_suite_id => 1016},
            {machine_id => 1002, test_suite_id => 1017},
            {machine_id => 1002, test_suite_id => 1018},
            {machine_id => 1002, test_suite_id => 1022},
            {machine_id => 1004, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1002, test_suite_id => 1026}, #update_121
            {machine_id => 1002, test_suite_id => 1027}, #update_122
            {machine_id => 1002, test_suite_id => 1028}, #update_123
            {machine_id => 1002, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-KDE-Live-i686',
        distri => 'opensuse',
        flavor => 'KDE-Live',
        arch => 'i686',
        variables => 'LIVECD=1;ISO_MAXSIZE=999_999_999',
        job_templates => [
            {machine_id => 1001, test_suite_id => 1002},
            {machine_id => 1005, test_suite_id => 1002}, # USB+kde
            {machine_id => 1001, test_suite_id => 1004},
            {machine_id => 1007, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1001, test_suite_id => 1013},
            {machine_id => 1001, test_suite_id => 1014},
            {machine_id => 1001, test_suite_id => 1015},
            {machine_id => 1001, test_suite_id => 1016},
            {machine_id => 1001, test_suite_id => 1017},
            {machine_id => 1001, test_suite_id => 1018},
            {machine_id => 1001, test_suite_id => 1021},
            {machine_id => 1003, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1001, test_suite_id => 1026}, #update_121
            {machine_id => 1001, test_suite_id => 1027}, #update_122
            {machine_id => 1001, test_suite_id => 1028}, #update_123
            {machine_id => 1001, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-KDE-Live-x86_64',
        distri => 'opensuse',
        flavor => 'KDE-Live',
        arch => 'x86_64',
        variables => 'LIVECD=1;ISO_MAXSIZE=999_999_999',
        job_templates => [
            {machine_id => 1002, test_suite_id => 1002},
            {machine_id => 1006, test_suite_id => 1002}, # USB+kde
            {machine_id => 1002, test_suite_id => 1004},
            {machine_id => 1008, test_suite_id => 1002}, # Laptop+gnome
            {machine_id => 1002, test_suite_id => 1013},
            {machine_id => 1002, test_suite_id => 1014},
            {machine_id => 1002, test_suite_id => 1015},
            {machine_id => 1002, test_suite_id => 1016},
            {machine_id => 1002, test_suite_id => 1017},
            {machine_id => 1002, test_suite_id => 1018},
            {machine_id => 1002, test_suite_id => 1021},
            {machine_id => 1004, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1002, test_suite_id => 1026}, #update_121
            {machine_id => 1002, test_suite_id => 1027}, #update_122
            {machine_id => 1002, test_suite_id => 1028}, #update_123
            {machine_id => 1002, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-NET-i586',
        distri => 'opensuse',
        flavor => 'NET',
        arch => 'i586',
        variables => 'ISO_MAXSIZE=4_700_372_992', # Bigger than needed
        job_templates => [
            {machine_id => 1001, test_suite_id => 1001},
            {machine_id => 1001, test_suite_id => 1002},
            {machine_id => 1001, test_suite_id => 1004},
            {machine_id => 1001, test_suite_id => 1005},
            {machine_id => 1001, test_suite_id => 1006},
            {machine_id => 1001, test_suite_id => 1007},
            {machine_id => 1001, test_suite_id => 1008},
            {machine_id => 1001, test_suite_id => 1010},
            {machine_id => 1001, test_suite_id => 1011},
            {machine_id => 1001, test_suite_id => 1012},
            {machine_id => 1005, test_suite_id => 1002}, # USB+kde
            {machine_id => 1007, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1007, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1001, test_suite_id => 1013},
            {machine_id => 1001, test_suite_id => 1014},
            {machine_id => 1001, test_suite_id => 1015},
            {machine_id => 1001, test_suite_id => 1016},
            {machine_id => 1001, test_suite_id => 1017},
            {machine_id => 1001, test_suite_id => 1018},
            {machine_id => 1003, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1001, test_suite_id => 1026}, #update_121
            {machine_id => 1001, test_suite_id => 1027}, #update_122
            {machine_id => 1001, test_suite_id => 1028}, #update_123
            {machine_id => 1001, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-NET-x86_64',
        distri => 'opensuse',
        flavor => 'NET',
        arch => 'x86_64',
        variables => 'ISO_MAXSIZE=4_700_372_992', # Bigger than needed
        job_templates => [
            {machine_id => 1002, test_suite_id => 1001},
            {machine_id => 1002, test_suite_id => 1002},
            {machine_id => 1002, test_suite_id => 1003},
            {machine_id => 1002, test_suite_id => 1004},
            {machine_id => 1002, test_suite_id => 1005},
            {machine_id => 1002, test_suite_id => 1006},
            {machine_id => 1002, test_suite_id => 1007},
            {machine_id => 1002, test_suite_id => 1008},
            {machine_id => 1002, test_suite_id => 1010},
            {machine_id => 1002, test_suite_id => 1011},
            {machine_id => 1002, test_suite_id => 1012},
            {machine_id => 1006, test_suite_id => 1002}, # USB+kde
            {machine_id => 1008, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1008, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1002, test_suite_id => 1013},
            {machine_id => 1002, test_suite_id => 1014},
            {machine_id => 1002, test_suite_id => 1015},
            {machine_id => 1002, test_suite_id => 1016},
            {machine_id => 1002, test_suite_id => 1017},
            {machine_id => 1002, test_suite_id => 1018},
            {machine_id => 1004, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1002, test_suite_id => 1026}, #update_121
            {machine_id => 1002, test_suite_id => 1027}, #update_122
            {machine_id => 1002, test_suite_id => 1028}, #update_123
            {machine_id => 1002, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-Rescue-i686',
        distri => 'opensuse',
        flavor => 'Rescue-CD',
        arch => 'i686',
        variables => 'LIVECD=1;ISO_MAXSIZE=681_574_400;RESCUECD=1',
        job_templates => [{machine_id => 1001, test_suite_id => 1023},]
    },
    Products => {
        name => 'oS-Rescue-x86_64',
        distri => 'opensuse',
        flavor => 'Rescue-CD',
        arch => 'x86_64',
        variables => 'LIVECD=1;ISO_MAXSIZE=681_574_400;RESCUECD=1',
        job_templates => [{machine_id => 1002, test_suite_id => 1023},]
    },
    Products => {
        name => 'oS-DVD-Biarch',
        distri => 'opensuse',
        flavor => 'DVD',
        arch => 'i586-x86_64',
        variables => 'ISO_MAXSIZE=8_539_996_160',
        job_templates => [
            {machine_id => 1001, test_suite_id => 1001},
            {machine_id => 1002, test_suite_id => 1002},
            {machine_id => 1001, test_suite_id => 1002},
            {machine_id => 1001, test_suite_id => 1004},
            {machine_id => 1001, test_suite_id => 1005},
            {machine_id => 1001, test_suite_id => 1006},
            {machine_id => 1001, test_suite_id => 1007},
            {machine_id => 1001, test_suite_id => 1008},
            {machine_id => 1001, test_suite_id => 1009},
            {machine_id => 1001, test_suite_id => 1010},
            {machine_id => 1001, test_suite_id => 1011},
            {machine_id => 1001, test_suite_id => 1012},
            {machine_id => 1005, test_suite_id => 1002}, # USB+kde
            {machine_id => 1007, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1007, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1001, test_suite_id => 1013},
            {machine_id => 1001, test_suite_id => 1014},
            {machine_id => 1001, test_suite_id => 1015},
            {machine_id => 1001, test_suite_id => 1016},
            {machine_id => 1001, test_suite_id => 1017},
            {machine_id => 1001, test_suite_id => 1018},
            {machine_id => 1003, test_suite_id => 1030}, #SMP+install_only (doesn't set NICEVIDEO)
            {machine_id => 1001, test_suite_id => 1026}, #update_121
            {machine_id => 1001, test_suite_id => 1027}, #update_122
            {machine_id => 1001, test_suite_id => 1028}, #update_123
            {machine_id => 1001, test_suite_id => 1029}, #dual_windows8
        ]
    },
    Products => {
        name => 'oS-Staging-x86_64',
        distri => 'opensuse',
        flavor => 'Staging-DVD',
        arch => 'x86_64',
        variables => 'ISO_MAXSIZE=4_700_372_992',
        job_templates => [{machine_id => 1001, test_suite_id => 1007},]
    },
    Products => {
        name => 'oS-Promo-i586',
        distri => 'opensuse',
        flavor => 'Promo-DVD',
        arch => 'i586',
        variables => 'ISO_MAXSIZE=4_700_372_992;PROMO=1',
        job_templates => [
            {machine_id => 1001, test_suite_id => 1002},
            {machine_id => 1001, test_suite_id => 1004},
            {machine_id => 1001, test_suite_id => 1005},
            {machine_id => 1001, test_suite_id => 1006},
            {machine_id => 1001, test_suite_id => 1007},
            {machine_id => 1001, test_suite_id => 1008},
            {machine_id => 1005, test_suite_id => 1002}, # USB+kde
            {machine_id => 1007, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1007, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1001, test_suite_id => 1021},
            {machine_id => 1001, test_suite_id => 1022},
        ]
    },
    Products => {
        name => 'oS-Promo-x86_64',
        distri => 'opensuse',
        flavor => 'Promo-DVD',
        arch => 'x86_64',
        variables => 'ISO_MAXSIZE=4_700_372_992;PROMO=1',
        job_templates => [
            {machine_id => 1002, test_suite_id => 1002},
            {machine_id => 1002, test_suite_id => 1003},
            {machine_id => 1002, test_suite_id => 1004},
            {machine_id => 1002, test_suite_id => 1005},
            {machine_id => 1002, test_suite_id => 1006},
            {machine_id => 1002, test_suite_id => 1007},
            {machine_id => 1002, test_suite_id => 1008},
            {machine_id => 1006, test_suite_id => 1002}, # USB+kde
            {machine_id => 1008, test_suite_id => 1002}, # Laptop+kde
            {machine_id => 1008, test_suite_id => 1005}, # Laptop+gnome
            {machine_id => 1002, test_suite_id => 1021},
            {machine_id => 1002, test_suite_id => 1022},
        ]
    },
    Products => {
        name => 'oS-OpenSourcePress-i586',
        distri => 'opensuse',
        flavor => 'Promo-DVD-OpenSourcePress',
        arch => 'i586',
        variables => 'ISO_MAXSIZE=4_700_372_992;PROMO=1',
        job_templates => [{machine_id => 1001, test_suite_id => 1021},{machine_id => 1001, test_suite_id => 1022},]
    },
    Products => {
        name => 'oS-OpenSourcePress-x86_64',
        distri => 'opensuse',
        flavor => 'Promo-DVD-OpenSourcePress',
        arch => 'x86_64',
        variables => 'ISO_MAXSIZE=4_700_372_992;PROMO=1',
        job_templates => [{machine_id => 1001, test_suite_id => 1021},{machine_id => 1001, test_suite_id => 1022},]
    },
]

# Promo-DVD, Promo-DVD-OpenSourcePress
