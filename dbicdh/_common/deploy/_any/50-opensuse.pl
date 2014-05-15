# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#!perl

use strict;
use warnings;

my $info =[
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
        id => 1003,
        name => 'smp_32',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu32" },{ key => "QEMUCPUS", value => "4" },{ key => "SMP", value => "1" },],
    },
    Machines => {
        id => 1004,
        name => 'smp_64',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu64" },{ key => "QEMUCPUS", value => "4" },{ key => "SMP", value => "1" },],
    },
    Machines => {
        id => 1005,
        name => 'USBboot_32',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu32" },{ key => "USBBOOT", value => "1" },],
    },
    Machines => {
        id => 1006,
        name => 'USBboot_64',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu64" },{ key => "USBBOOT", value => "1" },],
    },
    Machines => {
        id => 1007,
        name => 'Laptop_32',
        backend => 'qemu',
        variables => '',
        settings => [{ key => "QEMUCPU", value => "qemu32" },{ key => "LAPTOP", value => "1" },],
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
        id => 1003,
        name => "uefi",
        prio => 45,
        variables => '',
        settings => [{ key => "UEFI", value => 1 },{ key => "DESKTOP", value => "kde" },{ key => "INSTALLONLY", value => 1 },],
    },
    TestSuites => {
        id => 1004,
        name => "kde+btrfs",
        prio => 50,
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" },{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },],
    },
    TestSuites => {
        id => 1005,
        name => "gnome",
        prio => 45,
        variables => '',
        settings => [{ key => "DESKTOP", value => "gnome" }],
    },
    TestSuites => {
        id => 1006,
        name => "gnome+btrfs",
        prio => 50,
        variables => '',
        settings => [{ key => "DESKTOP", value => "gnome" },{ key => "LVM", value => 1 },{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },],
    },
    TestSuites => {
        id => 1007,
        name => "minimalx",
        prio => 45,
        variables => '',
        settings => [{ key => "DESKTOP", value => "minimalx" }],
    },
    TestSuites => {
        id => 1008,
        name => "minimalx+btrfs",
        prio => 50,
        variables => '',
        settings => [{ key => "DESKTOP", value => "minimalx" },{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },],
    },
    TestSuites => {
        id => 1009,
        name => "minimalx+btrfs+nosephome",
        prio => 50,
        variables => '',
        settings => [{ key => "DESKTOP", value => "minimalx" },{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },{ key => "INSTALLONLY", value => 1 },{ key => "TOGGLEHOME", value => 1 },],
    },
    TestSuites => {
        id => 1010,
        name => "textmode+btrfs",
        prio => 50,
        variables => '',
        settings => [{ key => "DESKTOP", value => "textmode" },{ key => "VIDEOMODE", value => "text" },{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },],
    },
    TestSuites => {
        id => 1011,
        name => "lxde",
        prio => 49,
        variables => '',
        settings => [{ key => "DESKTOP", value => "lxde" },{ key => "LVM", value => 1 },],
    },
    TestSuites => {
        id => 1012,
        name => "xfce",
        prio => 49,
        variables => '',
        settings => [{ key => "DESKTOP", value => "xfce" }],
    },
    TestSuites => {
        id => 1013,
        name => "RAID0",
        prio => 50,
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 0 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1014,
        name => "RAID1",
        prio => 51,
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 1 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1015,
        name => "RAID5",
        prio => 51,
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 5 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1016,
        name => "RAID10",
        prio => 51,
        variables => '',
        settings => [{ key => "RAIDLEVEL", value => 10 },{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1017,
        name => "btrfscryptlvm",
        prio => 50,
        variables => '',
        settings => [{ key => "BTRFS", value => 1 },{ key => "HDDSIZEGB", value => 20 },{ key => "ENCRYPT", value => 1 },{ key => "LVM", value => 1 },{ key => "NICEVIDEO", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1018,
        name => "cryptlvm",
        prio => 50,
        variables => '',
        settings => [{ key => "REBOOTAFTERINSTALL", value => 0 },{ key => "ENCRYPT", value => 1 },{ key => "LVM", value => 1 },{ key => "NICEVIDEO", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1019,
        name => "doc",
        prio => 60,
        variables => '',
        settings => [{ key => "DOCRUN", value => 1 },{ key => "QEMUVGA", value => "std" },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1020,
        name => "doc_de",
        prio => 60,
        variables => '',
        settings => [{ key => "DOCRUN", value => 1 },{ key => "QEMUVGA", value => "std" },{ key => "INSTLANG", value => "de_DE" },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1021,
        name => "kde-live",
        prio => 48,
        variables => '',
        settings => [{ key => "DESKTOP", value => "kde" },{ key => "LIVETEST", value => 1 },],
    },
    TestSuites => {
        id => 1022,
        name => "gnome-live",
        prio => 48,
        variables => '',
        settings => [{ key => "DESKTOP", value => "gnome" },{ key => "LIVETEST", value => 1 },],
    },
    TestSuites => {
        id => 1023,
        name => "rescue",
        prio => 49,
        variables => '',
        settings => [{ key => "DESKTOP", value => "xfce" },{ key => "LIVETEST", value => 1 },{ key => "NOAUTOLOGIN", value => 1 },{ key => "REBOOTAFTERINSTALL", value => 0 },],
    },
    TestSuites => {
        id => 1024,
        name => "nice",
        prio => 50,
        variables => '',
        settings => [{ key => "NICEVIDEO", value => 1 },{ key => "DOCRUN", value => 1 },{ key => "REBOOTAFTERINSTALL", value => 0 },{ key => "SCREENSHOTINTERVAL", value => 0.25 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1025,
        name => "splitusr",
        prio => 50,
        variables => '',
        settings => [{ key => "NICEVIDEO", value => 1 },{ key => "SPLITUSR", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1026,
        name => "update_121",
        prio => 50,
        variables => '',
        settings => [{ key => "UPGRADE", value => 1 },{ key => "HDD_1", value => "openSUSE-12.1-x86_64.hda" },{ key => "HDDVERSION", value => "openSUSE-12.1" },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1027,
        name => "update_122",
        prio => 50,
        variables => '',
        settings => [{ key => "UPGRADE", value => 1 },{ key => "HDD_1", value => "openSUSE-12.2-x86_64.hda" },{ key => "HDDVERSION", value => "openSUSE-12.2" },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1028,
        name => "update_123",
        prio => 50,
        variables => '',
        variables => '',
        settings => [{ key => "UPGRADE", value => 1 },{ key => "HDD_1", value => "openSUSE-12.3-x86_64.hda" },{ key => "HDDVERSION", value => "openSUSE-12.3" },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1029,
        name => "dual_windows8",
        prio => 50,
        variables => '',
        settings => [{ key => "HDD_1", value => "Windows-8.hda" },{ key => "HDDVERSION", value => "Windows 8" },{ key => "HDDMODEL", value => "ide-hd" },{ key => "DUALBOOT", value => 1 },{ key => "NUMDISKS", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    TestSuites => {
        id => 1030,
        name => "install_only",
        prio => 40,
        variables => '',
        settings => [{ key => "INSTALLONLY", value => 1 },{ key => "DESKTOP", value => "kde" },],
    },
    Products => {
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'DVD',
        arch => 'i586',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "DVD", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'DVD',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "DVD", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'GNOME-Live',
        arch => 'i686',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "999_999_999" },{ key => "GNOME", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'GNOME-Live',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "999_999_999" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'KDE-Live',
        arch => 'i686',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "999_999_999" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'KDE-Live',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "999_999_999" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'NET',
        arch => 'i586',
        variables => '', # Bigger than needed
        settings => [{ key => "ISO_MAXSIZE", value => "737_280_000" },{ key => "NETBOOT", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'NET',
        arch => 'x86_64',
        variables => '', # Bigger than needed
        settings => [{ key => "ISO_MAXSIZE", value => "737_280_000" },{ key => "NETBOOT", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Rescue-CD',
        arch => 'i686',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "681_574_400" },{ key => "RESCUECD", value => "1" },],
        job_templates => [{machine_id => 1001, test_suite_id => 1023},]
    },
    Products => {
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Rescue-CD',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "LIVECD", value => "1" },{ key => "ISO_MAXSIZE", value => "681_574_400" },{ key => "RESCUECD", value => "1" },],
        job_templates => [{machine_id => 1002, test_suite_id => 1023},]
    },
    Products => {
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'DVD',
        arch => 'i586-x86_64',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "8_539_996_160" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Staging:Core',
        flavor => 'Staging-DVD',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },],
        job_templates => [{machine_id => 1001, test_suite_id => 1007},]
    },
    Products => {
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Promo-DVD',
        arch => 'i586',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "PROMO", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Promo-DVD',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "PROMO", value => "1" },],
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
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Promo-DVD-OpenSourcePress',
        arch => 'i586',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "PROMO", value => "1" },],
        job_templates => [{machine_id => 1001, test_suite_id => 1021},{machine_id => 1001, test_suite_id => 1022},]
    },
    Products => {
        name => '',
        distri => 'opensuse',
        version => 'Factory',
        flavor => 'Promo-DVD-OpenSourcePress',
        arch => 'x86_64',
        variables => '',
        settings => [{ key => "ISO_MAXSIZE", value => "4_700_372_992" },{ key => "PROMO", value => "1" },],
        job_templates => [{machine_id => 1001, test_suite_id => 1021},{machine_id => 1001, test_suite_id => 1022},]
    },
];

# no use case for that yet
#use DBIx::Class::DeploymentHandler::DeployMethod::SQL::Translator::ScriptHelpers 'schema_from_schema_loader';

#schema_from_schema_loader({ naming => 'v4' },
sub {
    my $schema = shift;

    # [1] for deploy, [1,2] for upgrade or downgrade, probably used with _any
    my $versions = shift;

    for (my $i = 0; $i < @$info; $i++) {
        $schema->resultset($info->[$i])->create($info->[++$i]);
    }
  }
  #);
