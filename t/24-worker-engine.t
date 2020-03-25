# Copyright (C) 2018-2019 SUSE LLC
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

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use Test::Fatal;
use Test::More;
use Test::Warnings;
use OpenQA::Worker;
use OpenQA::Worker::Engines::isotovideo;
use Mojo::File 'path';

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";

subtest 'isotovideo version' => sub {
    like(
        exception {
            OpenQA::Worker::Engines::isotovideo::set_engine_exec('/bogus/location');
        },
        qr{Path to isotovideo invalid},
        'isotovideo version path invalid'
    );

    # init does not fail without isotovideo parameter
    # note that this might set the isotovideo version because the isotovideo path defaults
    # to /usr/bin/isotovideo
    my $worker1 = OpenQA::Worker->new({apikey => 'foo', apisecret => 'bar', instance => 1});

    my $isotovideo = path($FindBin::Bin)->child('fake-isotovideo.pl');
    my $worker2 = OpenQA::Worker->new({apikey => 'foo', apisecret => 'bar', instance => 1, isotovideo => $isotovideo});
    is($worker2->isotovideo_interface_version, 15, 'isotovideo version set from os-autoinst');
};

subtest 'asset settings' => sub {
    my $settings = {
        DISTRI                 => 'Unicorn',
        FLAVOR                 => 'pink',
        VERSION                => '42',
        BUILD                  => '666',
        ISO                    => 'whatever.iso',
        ISO_1                  => 'another.iso',
        ISO_2_URL              => 'http://example.net/third.iso',
        KERNEL                 => 'linux',
        INITRD                 => 'initrd',
        ASSET_1                => 'data.tar.gz',
        ASSET_2_URL            => 'https://example.net/file.dat',
        ASSET_2                => 'renamed.dat',
        ASSET_3_DECOMPRESS_URL => 'https://example.net/packed.dat.gz',
        ASSET_3                => 'unpacked.dat',
        DESKTOP                => 'DESKTOP',
        KVM                    => 'KVM',
        ISO_MAXSIZE            => 1,
        MACHINE                => 'RainbowPC',
        ARCH                   => 'x86_64',
        TEST                   => 'testA',
        NUMDISKS               => 3,
        WORKER_CLASS           => 'testAworker',
        UEFI_PFLASH_VARS       => 'however.qcow2'
    };

    my $expected = {
        'ISO'              => 'iso',
        'ISO_1'            => 'iso',
        'UEFI_PFLASH_VARS' => 'hdd',
        'KERNEL'           => 'other',
        'INITRD'           => 'other',
        'ASSET_1'          => 'other',
    };

    my $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (relative PFLASH)') or diag explain $got;

    # if UEFI_PFLASH_VARS is an absolute path, we should not treat it as an asset
    $settings->{UEFI_PFLASH_VARS} = '/absolute/path/OVMF_VARS.fd';
    delete($expected->{UEFI_PFLASH_VARS});

    $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (absolute PFLASH)') or diag explain $got;

    delete($settings->{UEFI_PFLASH_VARS});
    delete($settings->{NUMDISKS});

    $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (no UEFI or NUMDISKS)') or diag explain $got;
};


done_testing();
