#!/usr/bin/env perl
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::JobSettings;
use OpenQA::Test::TimeLimit '3';

my $settings = {
    BUILD_SDK => '%BUILD_HA%',
    BETA => 1,
    ISO_MAXSIZE => '4700372992',
    SHUTDOWN_NEEDS_AUTH => 1,
    HDD_1 => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
    PUBLISH_HDD_1 => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
    ANOTHER_JOB => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
    ARCH => 'x86_64',
    BACKEND => 'qemu',
    BUILD => '1234',
    BUILD_SLE => '%BUILD%',
    MACHINE => '64bit',
    PATCH => 1,
    UPGRADE => 1,
    ISO => 'SLE-%VERSION%-%FLAVOR%-%MACHINE%-Build%BUILD%-Media1.iso',
    WORKER_CLASS => 'qemu_x86_64',
    VERSION => '15-SP1',
    FLAVOR => 'Installer-DVD',
    ADDONURL_SDK => 'ftp://openqa.suse.de/SLE-%VERSION%-SDK-POOL-%ARCH%-Build%BUILD_SDK%-Media1/',
    DEPENDENCY_RESOLVER_FLAG => 1,
    DESKTOP => 'textmode',
    DEV_IMAGE => 1,
    HDDSIZEGB => 50,
    INSTALLONLY => 1,
    PATTERNS => 'base,minimal',
    PUBLISH_PFLASH_VARS =>
      'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed-uefi-vars.qcow2',
    SEPARATE_HOME => 0,
    BUILD_HA => '%BUILD%',
    BUILD_SES => '%BUILD%',
    WORKAROUND_MODULES => 'base,desktop,serverapp,script,sdk',
};

subtest expand_placeholders => sub {
    my $error = OpenQA::JobSettings::expand_placeholders($settings);
    my $match_settings = {
        BUILD_SDK => '1234',
        BETA => 1,
        ISO_MAXSIZE => '4700372992',
        SHUTDOWN_NEEDS_AUTH => 1,
        HDD_1 => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
        PUBLISH_HDD_1 => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
        ANOTHER_JOB => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
        ARCH => 'x86_64',
        BACKEND => 'qemu',
        BUILD => '1234',
        BUILD_SLE => '1234',
        MACHINE => '64bit',
        PATCH => 1,
        UPGRADE => 1,
        ISO => 'SLE-15-SP1-Installer-DVD-64bit-Build1234-Media1.iso',
        WORKER_CLASS => 'qemu_x86_64',
        VERSION => '15-SP1',
        FLAVOR => 'Installer-DVD',
        ADDONURL_SDK => 'ftp://openqa.suse.de/SLE-15-SP1-SDK-POOL-x86_64-Build1234-Media1/',
        DEPENDENCY_RESOLVER_FLAG => 1,
        DESKTOP => 'textmode',
        DEV_IMAGE => 1,
        HDDSIZEGB => 50,
        INSTALLONLY => 1,
        PATTERNS => 'base,minimal',
        PUBLISH_PFLASH_VARS => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed-uefi-vars.qcow2',
        SEPARATE_HOME => 0,
        BUILD_HA => '1234',
        BUILD_SES => '1234',
        WORKAROUND_MODULES => 'base,desktop,serverapp,script,sdk',
    };
    is($error, undef, "no error returned");
    is_deeply($settings, $match_settings, "Settings replaced");
};

subtest circular_reference => sub {
    my $circular_settings = {
        BUILD_SDK => '%BUILD_HA%',
        ISO_MAXSIZE => '4700372992',
        HDD_1 => 'SLES-%VERSION%-%ARCH%-%BUILD_HA%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
        PUBLISH_HDD_1 => 'SLES-%VERSION%-%ARCH%-%BUILD_HA%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
        ANOTHER_JOB => 'SLES-%VERSION%-%ARCH%-%BUILD_HA%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
        ARCH => 'x86_64',
        BACKEND => 'qemu',
        BUILD => '%BUILD_HA%',
        BUILD_HA => '%BUILD%',
        VERSION => '15-SP1',
        MACHINE => '64bit',
    };
    like(
        OpenQA::JobSettings::expand_placeholders($circular_settings),
        qr/The key (\w+) contains a circular reference, its value is %\w+%/,
        "circular reference exit successfully"
    );
};

subtest 'handle_plus_in_settings' => sub {
    my $settings = {
        'ISO' => 'foo.iso',
        '+ISO' => 'bar.iso',
        '+ARCH' => 'x86_64',
        'DISTRI' => 'opensuse',
    };
    OpenQA::JobSettings::handle_plus_in_settings($settings);
    is_deeply($settings, {ISO => 'bar.iso', ARCH => 'x86_64', DISTRI => 'opensuse'}, 'handle the plus correctly');
};

done_testing;
