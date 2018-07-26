# Copyright (C) 2018 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Warnings;
use OpenQA::Worker::Engines::isotovideo;

my $settings = {
    DISTRI           => 'Unicorn',
    FLAVOR           => 'pink',
    VERSION          => '42',
    BUILD            => '666',
    ISO              => 'whatever.iso',
    ISO_1            => 'another.iso',
    KERNEL           => 'linux',
    INITRD           => 'initrd',
    DESKTOP          => 'DESKTOP',
    KVM              => 'KVM',
    ISO_MAXSIZE      => 1,
    MACHINE          => 'RainbowPC',
    ARCH             => 'x86_64',
    TEST             => 'testA',
    NUMDISKS         => 3,
    WORKER_CLASS     => 'testAworker',
    UEFI_PFLASH_VARS => 'however.qcow2'
};

my $expected = {
    'ISO'              => 'iso',
    'ISO_1'            => 'iso',
    'UEFI_PFLASH_VARS' => 'hdd',
    'KERNEL'           => 'other',
    'INITRD'           => 'other',
};

my $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);

is_deeply($got, $expected, 'Asset settings are correct') or diag explain $got;

delete($expected->{UEFI_PFLASH_VARS});
delete($expected->{NUMDISKS});

delete($settings->{UEFI_PFLASH_VARS});
delete($settings->{NUMDISKS});

$got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
is_deeply($got, $expected, 'Asset settings are correct') or diag explain $got;

done_testing();
