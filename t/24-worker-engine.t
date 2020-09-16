# Copyright (C) 2018-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use OpenQA::Test::TimeLimit '12';
use Test::Fatal;
use Test::Warnings ':report_warnings';
use OpenQA::Worker;
use Test::MockModule;
use Test::MockObject;
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
        ISO_2                  => 'third.iso',
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
        'ISO_2'            => 'iso',
        'UEFI_PFLASH_VARS' => 'hdd',
        'KERNEL'           => 'other',
        'INITRD'           => 'other',
        'ASSET_1'          => 'other',
        'ASSET_2'          => 'other',
        'ASSET_3'          => 'other',
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

subtest 'caching' => sub {
    is(OpenQA::Worker::Engines::isotovideo::cache_assets, undef, 'cache_assets has nothing to do without assets');
    my %assets = (ISO => 'foo.iso',);
    my $got    = OpenQA::Worker::Engines::isotovideo::cache_assets(undef, undef, \%assets, undef, undef);
    is($got->{error}, undef, 'cache_assets can not pick up supplied assets when not found') or diag explain $got;
};

subtest 'asset caching' => sub {
    throws_ok { OpenQA::Worker::Engines::isotovideo::do_asset_caching() } qr/Need parameters/,
      'do_asset_caching needs parameters';
    my $asset_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
    $asset_mock->redefine(cache_assets => undef);
    my $got;
    my $job = Test::MockObject->new();
    my $testpool_server;
    $job->mock(client => sub { Test::MockObject->new()->set_bound(testpool_server => \$testpool_server) });
    $got = OpenQA::Worker::Engines::isotovideo::do_asset_caching($job);
    ok $job->called('client'), 'client has been asked for parameters when accessing job for caching';
    is $got, undef, 'Assets cached but not tests';
    $testpool_server = 'host1';
    my $prj_dir  = "FOO/$testpool_server";
    my $test_dir = "$prj_dir/tests";
    $asset_mock->redefine(sync_tests => $test_dir);
    $got = OpenQA::Worker::Engines::isotovideo::do_asset_caching($job);
    is($got, $test_dir, 'Cache directory updated');
};

done_testing();
