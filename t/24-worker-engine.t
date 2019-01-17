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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Output qw(combined_like);
use Test::Warnings;
use Test::MockModule;
use OpenQA::Worker::Engines::isotovideo;

$OpenQA::Worker::Common::current_host = 'this_host_should_not_exist';

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

subtest 'caching' => sub {
    is(OpenQA::Worker::Engines::isotovideo::cache_assets, undef, 'cache_assets has nothing to do without assets');
    combined_like(
        sub { $got = OpenQA::Worker::Engines::isotovideo::do_asset_caching($settings) },
        qr/^.*Cannot find.*asset.*$/,
        'Expected information about not found local asset'
    );
    like($got->{error}, qr/Cannot find .* asset/, 'Local assets are tried to be found on no caching')
      or diag explain $got;
    $OpenQA::Worker::Common::worker_settings = {CACHEDIRECTORY => 'FOO'};
    $OpenQA::Worker::Common::current_host    = 'host1';
    my $asset_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
    $asset_mock->mock(cache_assets        => sub { });
    $asset_mock->mock(locate_local_assets => sub { });
    $got = OpenQA::Worker::Engines::isotovideo::do_asset_caching($settings);
    is($got, undef, 'Assets cached but not tests');
    $OpenQA::Worker::Common::hosts->{host1} = {testpoolserver => 'foo'};
    $asset_mock->mock(sync_tests => sub { });
    my $shared_cache;
    ($got, $shared_cache) = OpenQA::Worker::Engines::isotovideo::do_asset_caching($settings);
    is($got,          undef,             'No error reported');
    is($shared_cache, 'FOO/host1/tests', 'Cache directory updated');
    $asset_mock->unmock('cache_assets');
    my %assets       = (ISO => 'foo.iso',);
    my $cache_client = Test::MockModule->new('OpenQA::Worker::Cache::Client');
    $cache_client->mock(availability_error => undef);
    $cache_client->mock(asset_exists       => undef);
    $cache_client->mock(path               => undef);
    $cache_client->mock(asset_path         => '/path/to/asset');
    my $cache_request = Test::MockModule->new('OpenQA::Worker::Cache::Request');
    $cache_request->mock(enqueue => undef);
    $cache_request->mock(asset   => sub { return OpenQA::Worker::Cache::Request->new });
    $got = OpenQA::Worker::Engines::isotovideo::cache_assets(undef, $settings, \%assets);
    like($got->{error}, qr/Failed to download/, 'cache_assets can not pick up supplied assets when not found')
      or diag explain $got;
};

done_testing();
