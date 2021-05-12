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
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Constants 'WORKER_EC_ASSET_FAILURE';
use Test::Fatal;
use Test::Warnings ':report_warnings';
use OpenQA::Worker;
use Test::MockModule;
use Test::MockObject;
use Test::Output qw(combined_like combined_unlike);
use OpenQA::Worker::Engines::isotovideo;
use Mojo::File qw(path tempdir);
use Mojo::JSON 'decode_json';
use OpenQA::Utils qw(testcasedir productdir);

# define fake packages for testing asset caching
{
    package Test::FakeJob;
    use Mojo::Base -base;
    has id => 42;
}
{
    package Test::FakeRequest;
    use Mojo::Base -base;
    has minion_id => 13;
}

# Fake worker, client
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number => 1;
    has settings        => sub { OpenQA::Worker::Settings->new(1, {}) };
    has pool_directory  => undef;
}
{
    package Test::FakeClient;
    use Mojo::Base -base;
    has worker_id  => 1;
    has webui_host => 'localhost';
}

$ENV{OPENQA_CONFIG}   = "$FindBin::Bin/data/24-worker-overall";
$ENV{OPENQA_HOSTNAME} = "localhost";

sub get_job_json_data {
    my ($pool_dir) = @_;
    my $vars_json = path($pool_dir)->child("vars.json")->slurp;
    return decode_json $vars_json;
}

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
    my %assets = (ISO => 'foo.iso');
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

subtest 'problems when caching assets' => sub {
    my $cache_client_mock = Test::MockModule->new('OpenQA::CacheService::Client');
    $cache_client_mock->redefine(asset_path    => 'some/path');
    $cache_client_mock->redefine(enqueue       => 'some enqueue error');
    $cache_client_mock->redefine(asset_request => Test::FakeRequest->new);
    $cache_client_mock->redefine(
        info => OpenQA::CacheService::Response::Info->new(data => {active_workers => 1}, error => undef));
    $cache_client_mock->redefine(
        status => OpenQA::CacheService::Response::Status->new(
            data => {
                status => 'processed',
                output => 'Download of "FOO" failed: 404 Not Found'
            }));

    my $result;
    my @args = (Test::FakeJob->new, {ISO_1 => 'FOO'}, {ISO_1 => 'iso'}, 'webuihost');

    $result = OpenQA::Worker::Engines::isotovideo::cache_assets(@args);
    is(
        $result->{error},
        'Failed to send asset request for FOO: some enqueue error',
        'failed to enqueue request for asset download'
    );
    is($result->{category}, undef, 'no category set so problem is treated as cache service failure');

    $cache_client_mock->redefine(enqueue => 0);
    $result = OpenQA::Worker::Engines::isotovideo::cache_assets(@args);
    is($result->{error},    'Failed to download FOO to some/path', 'asset not found');
    is($result->{category}, WORKER_EC_ASSET_FAILURE, 'category set so problem is treated as asset failure');

};

subtest 'symlink testrepo' => sub {
    my $worker         = Test::FakeWorker->new;
    my $client         = Test::FakeClient->new;
    my $settings       = {DISTRI => 'foo'};
    my $job            = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => $settings});
    my $pool_directory = tempdir('poolXXXX');
    my $casedir        = testcasedir('foo', undef, undef);
    $worker->pool_directory($pool_directory);
    my $result = OpenQA::Worker::Engines::isotovideo::engine_workit($job);
    like $result->{error}, qr/The source directory $casedir does not exist/,
      'symlink failed because the source directory does not exist';

    $settings->{DISTRI} = 'opensuse';
    $casedir            = testcasedir('opensuse', undef, undef);
    $job                = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => $settings});
    chmod(0444, $pool_directory);
    $result = OpenQA::Worker::Engines::isotovideo::engine_workit($job);
    like $result->{error}, qr/Cannot create symlink from "$casedir" to "$pool_directory\/opensuse": Permission denied/,
      'symlink failed because permission denied';
    chmod(0755, $pool_directory);

    delete $settings->{DISTRI};
    $settings->{NEEDLES_DIR} = 'needles';
    $casedir                 = testcasedir(undef, undef, undef);
    $job                     = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => $settings});
    $result                  = OpenQA::Worker::Engines::isotovideo::engine_workit($job);
    like $result->{error}, qr/The source directory $casedir\/needles does not exist/,
      'symlink needles directory failed because source directory does not exist';

    $casedir = testcasedir('opensuse', undef, undef);
    $result  = OpenQA::Worker::Engines::isotovideo::_link_repo($casedir, $pool_directory, 'opensuse');
    is $result, undef, 'create symlink successfully';

    $settings->{DISTRI}      = 'fedora';
    $settings->{JOBTOKEN}    = 'token99916';
    $settings->{NEEDLES_DIR} = 'fedora/needles';
    $settings->{CASEDIR}     = 'https://github.com/foo/os-autoinst-distri-example.git#master';
    my $productdir = productdir('fedora', undef, undef);
    $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => $settings});
    combined_like { $result = OpenQA::Worker::Engines::isotovideo::engine_workit($job) }
    qr /Symlinked from "t\/data\/openqa\/share\/tests\/fedora\/needles" to "$pool_directory\/needles"/,
      'symlink needles_dir';
    like $result->{child}->process_id, qr/\d+/, 'don\'t create symlink when CASEDIR is an url address';
    my $vars_data = get_job_json_data($pool_directory);
    is $vars_data->{PRODUCTDIR}, 't/data/openqa/share/tests/fedora',
      'PRODUCTDIR is the default value when CASEDIR is a github address and not define PRODUCTDIR';
    is $vars_data->{NEEDLES_DIR}, 'needles', 'When NEEDLES_DIR is a relative path, set it to basename';
};

subtest 'don\'t do symlink when job settings include ABSOLUTE_TEST_CONFIG_PATHS=1' => sub {
    my $worker         = Test::FakeWorker->new;
    my $client         = Test::FakeClient->new;
    my $settings       = {DISTRI => 'fedora', JOBTOKEN => 'token000', ABSOLUTE_TEST_CONFIG_PATHS => 1};
    my $job            = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => $settings});
    my $pool_directory = tempdir('poolXXXX');
    $worker->pool_directory($pool_directory);
    combined_unlike { my $result = OpenQA::Worker::Engines::isotovideo::engine_workit($job) }
    qr/Symlinked from/, 'don\'t do symlink when jobs have the ABSOLUTE_TEST_CONFIG_PATHS=1';
    my $vars_data  = get_job_json_data($pool_directory);
    my $productdir = productdir('fedora', undef, undef);
    my $casedir    = testcasedir('fedora', undef, undef);
    is $vars_data->{PRODUCTDIR}, $productdir, 'PRODUCTDIR was not overwritten';
    is $vars_data->{CASEDIR},    $casedir,    'CASEDIR was not overwritten';
};

done_testing();
