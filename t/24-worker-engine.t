# Copyright (C) 2018-2021 SUSE LLC
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
use Mojo::Base -signatures;

BEGIN { $ENV{OPENQA_CACHE_SERVICE_POLL_DELAY} = 0 }

use File::Spec::Functions qw(abs2rel);
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
use OpenQA::Utils qw(testcasedir productdir needledir locate_asset);

# define fake packages for testing asset caching
{
    package Test::FakeJob;    # uncoverable statement count:2
    use Mojo::Base -base;
    has id     => 42;
    has worker => undef;
    sub post_setup_status      { 1 }
    sub is_stopped_or_stopping { 0 }
}
{
    package Test::FakeRequest;    # uncoverable statement count:2
    use Mojo::Base -base;
    has minion_id => 13;
}

# Fake worker, client
{
    package Test::FakeWorker;     # uncoverable statement count:2
    use Mojo::Base -base;
    has instance_number => 1;
    has settings        => sub { OpenQA::Worker::Settings->new(1, {}) };
    has pool_directory  => undef;
}
{
    package Test::FakeClient;     # uncoverable statement count:2
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

sub _run_engine ($job) {
    my $result;
    my $cb = sub ($res) { $result = $res; Mojo::IOLoop->stop };
    OpenQA::Worker::Engines::isotovideo::engine_workit($job, $cb);
    Mojo::IOLoop->start;
    return $result;
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
    my $error = 'not called';
    my $cb    = sub ($err) { $error = $err };
    OpenQA::Worker::Engines::isotovideo::cache_assets(undef, undef, undef, [], undef, undef, undef, $cb);
    is $error, undef, 'cache_assets has nothing to do without assets';

    my %assets = (ISO => 'foo.iso');
    $error = 'not called';
    OpenQA::Worker::Engines::isotovideo::cache_assets(undef, undef, undef, [keys %assets], \%assets, undef, undef, $cb);
    is $error, undef, 'cache_assets can not pick up supplied assets when not found';
};

subtest 'asset caching' => sub {
    my $asset_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
    $asset_mock->redefine(
        cache_assets =>
          sub ($cache_client, $job, $vars, $assets_to_cache, $assetkeys, $webui_host, $pooldir, $callback) {
            $callback->(undef);
        });
    my $job = Test::MockObject->new;
    my $testpool_server;
    $job->mock(client => sub { Test::MockObject->new->set_bound(testpool_server => \$testpool_server) });
    my $error = 'not called';
    my $cb    = sub ($err) { $error = $err; Mojo::IOLoop->stop };
    OpenQA::Worker::Engines::isotovideo::do_asset_caching($job, undef, undef, undef, undef, undef, $cb);
    Mojo::IOLoop->start;
    ok $job->called('client'), 'client has been asked for parameters when accessing job for caching';
    is $error, undef, 'Assets cached but not tests';
    $testpool_server = 'host1';
    my $prj_dir  = "FOO/$testpool_server";
    my $test_dir = "$prj_dir/tests";
    $asset_mock->redefine(
        sync_tests => sub ($cache_client, $job, $vars, $shared_cache, $rsync_source, $remaining_tries, $callback) {
            $callback->($test_dir);
        });
    OpenQA::Worker::Engines::isotovideo::do_asset_caching($job, undef, 'foo', undef, 'bar', undef, $cb);
    Mojo::IOLoop->start;
    is $error, $test_dir, 'Cache directory updated';
};

sub _mock_cache_service_client ($status_data) {
    my $cache_client_mock = Test::MockModule->new('OpenQA::CacheService::Client');
    $cache_client_mock->redefine(enqueue => 'some enqueue error');
    $cache_client_mock->redefine(
        info => OpenQA::CacheService::Response::Info->new(data => {active_workers => 1}, error => undef));
    $cache_client_mock->redefine(status => OpenQA::CacheService::Response::Status->new(data => $status_data));
    return $cache_client_mock;
}

subtest 'problems when caching assets' => sub {
    my %fake_status       = (status => 'processed', output => 'Download of "FOO" failed: 404 Not Found');
    my $cache_client_mock = _mock_cache_service_client \%fake_status;
    $cache_client_mock->redefine(asset_path    => 'some/path');
    $cache_client_mock->redefine(asset_request => Test::FakeRequest->new);

    my $error  = 'not called';
    my $cb     = sub ($err) { $error = $err; Mojo::IOLoop->stop };
    my $job    = Test::FakeJob->new;
    my @assets = ('ISO_1');
    my @args   = ($job, {ISO_1 => 'FOO'}, \@assets, {ISO_1 => 'iso'}, 'webuihost', undef, $cb);
    OpenQA::Worker::Engines::isotovideo::cache_assets(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $error->{error}, 'Failed to send asset request for FOO: some enqueue error',
      'failed to enqueue request for asset download';
    is $error->{category}, undef, 'no category set so problem is treated as cache service failure';

    $cache_client_mock->redefine(enqueue => 0);
    @assets = ('ISO_1');
    OpenQA::Worker::Engines::isotovideo::cache_assets(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $error->{error}, 'Failed to download FOO to some/path', 'asset not found';
    is $error->{category}, WORKER_EC_ASSET_FAILURE, 'category set so problem is treated as asset failure';

    my $asset_uri = $FindBin::Bin;    # just pass something existing here
    my %vars;
    my $status = OpenQA::CacheService::Response::Status->new(data => {});
    @args = (OpenQA::CacheService::Client->new, 'UEFI_PFLASH_VARS', $asset_uri, $status, \%vars, undef, undef);
    is OpenQA::Worker::Engines::isotovideo::_handle_asset_processed(@args), undef, 'no error for UEFI_PFLASH_VARS';
    is $vars{UEFI_PFLASH_VARS}, $asset_uri, 'specified asset URI set to vars';
};

subtest 'syncing tests' => sub {
    my %fake_status       = (status => 'processed', output => 'Fake rsync output', result => 'exit code 10');
    my $cache_client_mock = _mock_cache_service_client \%fake_status;
    $cache_client_mock->redefine(rsync_request => Test::FakeRequest->new(result => 'exit code 10'));

    my $worker = Test::FakeWorker->new;
    my $result = 'not called';
    my $cb     = sub ($res) { $result = $res; Mojo::IOLoop->stop };
    my @args = (Test::FakeJob->new(worker => $worker), {ISO_1 => 'iso'}, 'cache-dir/webuihost', 'rsync-source', 2, $cb);
    OpenQA::Worker::Engines::isotovideo::sync_tests(OpenQA::CacheService::Client->new, @args);
    is $result->{error},
      "Failed to send rsync from 'rsync-source' to 'cache-dir/webuihost': some enqueue error",
      'failed to enqueue request for rsync';
    is $result->{category}, undef, 'no category set so problem is treated as cache service failure (1)';

    $cache_client_mock->redefine(enqueue => 0);
    OpenQA::Worker::Engines::isotovideo::sync_tests(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $result->{error}, 'Failed to rsync tests: exit code 10';
    is $result->{category}, undef, 'no category set so problem is treated as cache service failure (2)';

    my $status_response = OpenQA::CacheService::Response::Status->new(data => {output => 'foo', status => 'processed'});
    $cache_client_mock->redefine(status => $status_response);
    OpenQA::Worker::Engines::isotovideo::sync_tests(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $result, 'cache-dir/webuihost/tests', 'returns synced test directory on success' or diag explain $result;
};

subtest 'symlink testrepo' => sub {
    my $pool_directory = tempdir('poolXXXX');
    my $worker         = Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client         = Test::FakeClient->new;

    subtest 'error case: CASEDIR missing' => sub {
        my $job     = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {DISTRI => 'foo'}});
        my $result  = _run_engine($job);
        my $casedir = testcasedir('foo', undef, undef);
        like $result->{error}, qr/The source directory $casedir does not exist/,
          'symlink failed because the source directory does not exist';
    };

    subtest 'error case: permission denied' => sub {
        chmod(0444, $pool_directory);
        my $job     = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {DISTRI => 'opensuse'}});
        my $result  = _run_engine($job);
        my $casedir = testcasedir('opensuse', undef, undef);
        like $result->{error},
          qr/Cannot create symlink from "$casedir" to "$pool_directory\/opensuse": Permission denied/,
          'symlink failed because permission denied';

    };
    chmod(0755, $pool_directory);

    subtest 'error case: NEEDLES_DIR missing' => sub {
        my $job     = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {NEEDLES_DIR => 'needles'}});
        my $result  = _run_engine($job);
        my $casedir = testcasedir(undef, undef, undef);
        like $result->{error}, qr/The source directory $casedir\/needles does not exist/,
          'symlink needles directory failed because source directory does not exist';
    };

    subtest 'good case: direct invocation of helper function for symlinking' => sub {
        my $casedir = testcasedir('opensuse', undef, undef);
        my $result  = OpenQA::Worker::Engines::isotovideo::_link_repo($casedir, $pool_directory, 'opensuse');
        is $result, undef, 'create symlink successfully';
    };

    my @custom_casedir_settings = (
        CASEDIR     => 'https://github.com/foo/os-autoinst-distri-example.git#master',
        NEEDLES_DIR => 'fedora/needles',
        DISTRI      => 'fedora',
        JOBTOKEN    => 'token99916',
    );

    subtest 'good case: custom CASEDIR and custom NEEDLES_DIR specified' => sub {
        my %job_settings = (id => 12, settings => {@custom_casedir_settings, NEEDLES_DIR => 'fedora/needles'});
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        combined_like { $result = _run_engine($job) }
        qr {Symlinked from "t/data/openqa/share/tests/fedora/needles" to "$pool_directory/needles"},
          'symlink for needles dir created, points to default dir despite custom CASEDIR';
        my $vars_data = get_job_json_data($pool_directory);
        my $casedir   = testcasedir('fedora', undef, undef);
        is $vars_data->{PRODUCTDIR}, abs2rel(productdir('fedora', undef, undef), $casedir),
          'PRODUCTDIR still defaults to a relative path when CASEDIR is a URL to main.pm from custom test repo is used';
        is $vars_data->{NEEDLES_DIR}, 'needles', 'relative NEEDLES_DIR is set to its basename';
        is $result->{error},          undef,     'no error occurred (1)';
    };

    subtest 'good case: custom CASEDIR specified but no custom NEEDLES_DIR' => sub {
        my %job_settings = (id => 12, settings => {@custom_casedir_settings});
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        combined_like { $result = _run_engine($job) }
        qr {Symlinked from "t/data/openqa/share/tests/fedora/needles" to "$pool_directory/needles"},
          'symlink for needles dir also created without NEEDLES_DIR, points to default dir despite custom CASEDIR';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{NEEDLES_DIR}, 'needles', 'relative NEEDLES_DIR is set to name of symlink';
        is $result->{error},          undef,     'no error occurred (2)';

    };
};

subtest 'behavior with ABSOLUTE_TEST_CONFIG_PATHS=1' => sub {
    my $pool_directory = tempdir('poolXXXX');
    my $worker         = Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client         = Test::FakeClient->new;
    my @settings       = (DISTRI => 'fedora', JOBTOKEN => 'token000', ABSOLUTE_TEST_CONFIG_PATHS => 1);

    subtest 'don\'t do symlink when job settings include ABSOLUTE_TEST_CONFIG_PATHS=1' => sub {
        my %settings = (@settings, HDD_1 => 'foo.qcow2');
        my $job      = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => \%settings});
        combined_unlike { _run_engine($job) }
        qr/Symlinked from/, 'don\'t do symlink when jobs have the ABSOLUTE_TEST_CONFIG_PATHS=1';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{PRODUCTDIR}, productdir('fedora', undef, undef),  'default PRODUCTDIR assigned';
        is $vars_data->{CASEDIR},    testcasedir('fedora', undef, undef), 'default CASEDIR assigned';
        is $vars_data->{HDD_1},      locate_asset('hdd', 'foo.qcow2'),
          'don\'t symlink asset when using ABSOLUTE_TEST_CONFIG_PATHS=>1';
        is $vars_data->{NEEDLES_DIR}, undef, 'no NEEDLES_DIR assigned';
    };

    subtest 'absolute default NEEDLES_DIR with ABSOLUTE_TEST_CONFIG_PATHS=1 and custom CASEDIR' => sub {
        my %settings = (@settings, CASEDIR => 'git:foo/bar');
        my $job      = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => \%settings});
        combined_unlike { _run_engine($job) }
        qr/Symlinked from/, 'don\'t do symlink when jobs have the ABSOLUTE_TEST_CONFIG_PATHS=1';
        my $vars_data           = get_job_json_data($pool_directory);
        my $expected_productdir = abs2rel(productdir('fedora', undef, undef), testcasedir('fedora', undef, undef));
        is $vars_data->{NEEDLES_DIR}, needledir('fedora', undef, undef), 'default NEEDLES_DIR assigned';
        is $vars_data->{CASEDIR},     $settings{CASEDIR}, 'custom CASEDIR not touched';
        is $vars_data->{PRODUCTDIR},  $expected_productdir,
          'nevertheless relative PRODUCTDIR assigned to load main.pm from custom CASEDIR';
    };
};


subtest 'symlink asset' => sub {
    my $pool_directory = tempdir('poolXXXX');
    my $worker         = Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client         = Test::FakeClient->new;
    my $settings
      = {JOBTOKEN => 'token000', ISO => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso', HDD_1 => 'foo.qcow2'};
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => $settings});
    combined_like { my $result = _run_engine($job) }
    qr/Linked asset/, 'linked asset';
    my $vars_data = get_job_json_data($pool_directory);
    ok(-e "$pool_directory/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso", 'the iso is symlinked to pool directory');
    ok(-e "$pool_directory/foo.qcow2",                                    'the hdd is symlinked to pool directory');
    is $vars_data->{ISO}, 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
      'the value of ISO is basename when doing symlink';
    is $vars_data->{HDD_1}, 'foo.qcow2', 'the value of HDD_1 is basename when doing symlink';
};

done_testing();
