# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use Mojo::Base -signatures;

BEGIN {
    $ENV{OPENQA_CACHE_SERVICE_POLL_DELAY} = 0;
    delete $ENV{OPENQA_CACHE_MAX_INACTIVE_JOBS};
    delete $ENV{OPENQA_CACHE_MAX_INACTIVE_JOBS_HARD_LIMIT};
}

use File::Spec::Functions qw(abs2rel catdir);
use OpenQA::Constants 'WORKER_EC_ASSET_FAILURE';
use Test::Warnings ':report_warnings';
use OpenQA::Worker;
use Test::MockModule;
use Test::MockObject;
use Test::Output qw(combined_like combined_unlike combined_from);
use OpenQA::Worker::Engines::isotovideo;
use OpenQA::Test::FakeWorker;
use Mojo::File qw(path tempdir);
use Mojo::JSON 'decode_json';
use OpenQA::Utils qw(testcasedir productdir needledir locate_asset base_host);
use Cwd qw(getcwd);
use Mojo::Util 'scope_guard';
use File::Copy::Recursive qw(dircopy);

my $workdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
chdir $workdir;
my $guard = scope_guard sub { chdir $FindBin::Bin };
dircopy "$FindBin::Bin/$_", "$workdir/t/$_" or BAIL_OUT($!) for qw(data);

# define fake packages for testing asset caching
package Test::FakeJob {
    use Mojo::Base -base;
    has id => 42;
    has worker => undef;
    has client => sub { Test::FakeClient->new };
    sub post_setup_status { 1 }
    sub is_stopped_or_stopping { 0 }
}    # uncoverable statement

package Test::FakeRequest {
    use Mojo::Base -base;
    has minion_id => 13;
}    # uncoverable statement

# Fake client
# uncoverable statement count:1
package Test::FakeClient {
    use Mojo::Base -base;
    has worker_id => 1;
    has webui_host => 'localhost';
    has service_port_delta => 2;
    has testpool_server => 'fake-testpool-server';
}    # uncoverable statement

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";
$ENV{OPENQA_HOSTNAME} = "localhost";

sub get_job_json_data ($pool_dir) {
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
    throws_ok {
        OpenQA::Worker::Engines::isotovideo::set_engine_exec('/bogus/location');
    }
    qr{Path to isotovideo invalid}, 'isotovideo version path invalid';

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
        DISTRI => 'Unicorn',
        FLAVOR => 'pink',
        VERSION => '42',
        BUILD => '666',
        ISO => 'whatever.iso',
        ISO_1 => 'another.iso',
        ISO_2_URL => 'http://example.net/third.iso',
        ISO_2 => 'third.iso',
        KERNEL => 'linux',
        INITRD => 'initrd',
        ASSET_1 => 'data.tar.gz',
        ASSET_2_URL => 'https://example.net/file.dat',
        ASSET_2 => 'renamed.dat',
        ASSET_3_DECOMPRESS_URL => 'https://example.net/packed.dat.gz',
        ASSET_3 => 'unpacked.dat',
        DESKTOP => 'DESKTOP',
        KVM => 'KVM',
        ISO_MAXSIZE => 1,
        MACHINE => 'RainbowPC',
        ARCH => 'x86_64',
        TEST => 'testA',
        NUMDISKS => 3,
        WORKER_CLASS => 'testAworker',
        UEFI_PFLASH_VARS => 'however.qcow2'
    };

    my $expected = {
        'ISO' => 'iso',
        'ISO_1' => 'iso',
        'ISO_2' => 'iso',
        'UEFI_PFLASH_VARS' => 'hdd',
        'KERNEL' => 'other',
        'INITRD' => 'other',
        'ASSET_1' => 'other',
        'ASSET_2' => 'other',
        'ASSET_3' => 'other',
    };

    my $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (relative PFLASH)') or always_explain $got;

    # if UEFI_PFLASH_VARS is an absolute path, we should not treat it as an asset
    $settings->{UEFI_PFLASH_VARS} = '/absolute/path/OVMF_VARS.fd';
    delete($expected->{UEFI_PFLASH_VARS});

    $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (absolute PFLASH)') or always_explain $got;

    delete($settings->{UEFI_PFLASH_VARS});
    delete($settings->{NUMDISKS});

    $got = OpenQA::Worker::Engines::isotovideo::detect_asset_keys($settings);
    is_deeply($got, $expected, 'Asset settings are correct (no UEFI or NUMDISKS)') or always_explain $got;
};

subtest 'caching' => sub {
    my $error = 'not called';
    my $cb = sub ($err) { $error = $err };
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
    my $cb = sub ($err) { $error = $err; Mojo::IOLoop->stop };
    OpenQA::Worker::Engines::isotovideo::do_asset_caching($job, undef, undef, undef, undef, undef, $cb);
    Mojo::IOLoop->start;
    ok $job->called('client'), 'client has been asked for parameters when accessing job for caching';
    is $error, undef, 'Assets cached but not tests';
    $testpool_server = 'host1';
    my $prj_dir = "FOO/$testpool_server";
    my $test_dir = "$prj_dir/tests";
    $asset_mock->redefine(
        sync_tests => sub ($cache_client, $job, $vars, $shared_cache, $rsync_source, $remaining_tries, $callback) {
            $callback->($test_dir);
        });
    OpenQA::Worker::Engines::isotovideo::do_asset_caching($job, undef, 'foo', undef, 'bar', undef, $cb);
    Mojo::IOLoop->start;
    is $error, $test_dir, 'Cache directory updated';
};

sub _mock_cache_service_client ($status_data, $info_data = undef, $error = undef) {
    my $cache_client_mock = Test::MockModule->new('OpenQA::CacheService::Client');
    $info_data //= {active_workers => 1};
    $cache_client_mock->redefine(enqueue => 'some enqueue error');
    $cache_client_mock->redefine(info => OpenQA::CacheService::Response::Info->new(data => $info_data, error => undef));
    $cache_client_mock->redefine(
        status => OpenQA::CacheService::Response::Status->new(data => $status_data, error => $error));
    return $cache_client_mock;
}

subtest 'handling availability error' => sub {
    my %fake_status = (active_workers => 1, inactive_jobs => 46);
    my $cache_client_mock = _mock_cache_service_client {}, \%fake_status;
    my $cache_client = OpenQA::CacheService::Client->new;
    my $cb_res;
    my $cb = sub ($res) { $cb_res = $res };
    my @args = ($cache_client, Test::FakeJob->new, {a => 1}, [('a') x 2], {}, 'webuihost', undef, $cb);
    OpenQA::Worker::Engines::isotovideo::cache_assets @args;
    like $cb_res->{error}, qr/Cache service queue already full/, 'error when hard-limit exceeded';

    $fake_status{inactive_jobs} = 45;
    OpenQA::Worker::Engines::isotovideo::cache_assets @args;
    like $cb_res->{error}, qr/Failed to send asset request/, 'attempt to cache when below hard-limit';
};

subtest 'problems and special cases when caching assets' => sub {
    my %fake_status = (status => 'processed', output => 'Download of "FOO" failed: 404 Not Found');
    my $cache_client_mock = _mock_cache_service_client \%fake_status;
    $cache_client_mock->redefine(asset_path => 'some/path');
    $cache_client_mock->redefine(asset_request => Test::FakeRequest->new);

    my $error = 'not called';
    my $cb = sub ($err) { $error = $err; Mojo::IOLoop->stop };
    my $job = Test::FakeJob->new;
    my %vars = (ISO_1 => 'FOO', CASEDIR => 'https://foo.git', NEEDLES_DIR => 'https://bar.git');
    my @assets = ('ISO_1');
    my @args = ($job, \%vars, \@assets, {ISO_1 => 'iso'}, 'webuihost', undef, $cb);
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

    $cache_client_mock = _mock_cache_service_client {}, undef, 'some severe error';
    $cache_client_mock->redefine(asset_request => Test::FakeRequest->new);
    $cache_client_mock->redefine(enqueue => 0);
    @assets = ('ISO_1');
    OpenQA::Worker::Engines::isotovideo::cache_assets(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $error->{error}, 'some severe error', 'job not "processed" due to some error';

    subtest 'test sync skipped for Git-only jobs' => sub {
        my $isotovideo_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
        my $sync_tests_called;
        $isotovideo_mock->redefine(cache_assets => sub (@args) { $args[-1]->(undef) });
        $isotovideo_mock->redefine(sync_tests => sub (@) { $sync_tests_called = 1 });

        OpenQA::Worker::Engines::isotovideo::do_asset_caching(@args);
        is $error, undef, 'callback called without error (1)';
        is $sync_tests_called, undef, 'sync tests was not called for Git-only job (separate needles repo)';

        delete $vars{NEEDLES_DIR};    # no NEEDLES_DIR means needles are within CASEDIR or separate
        OpenQA::Worker::Engines::isotovideo::do_asset_caching(@args);
        is $error, undef, 'callback called without error (2)';
        is $sync_tests_called, 1, 'sync tests was called for job where needles might be separate';

        $vars{NEEDLES_DIR} = 'relative/path';    # considered relative to default needles, relying on sync
        $sync_tests_called = undef;
        OpenQA::Worker::Engines::isotovideo::do_asset_caching(@args);
        is $error, undef, 'callback called without error (3)';
        is $sync_tests_called, 1, 'sync tests called with relative NEEDLES_DIR (relative to default needles)';

        delete $vars{CASEDIR};    # no CASEDIR means using default checkout, relying on sync
        undef $sync_tests_called;
        OpenQA::Worker::Engines::isotovideo::do_asset_caching(@args);
        is $error, undef, 'callback called without error (4)';
        is $sync_tests_called, 1, 'sync tests was called for job not using Git at all';
    };
};

subtest '_handle_asset_processed' => sub {
    my %fake_status = (status => 'processed', output => 'Download of "FOO" failed: 404 Not Found');
    my $module = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
    $module->mock(
        '_link_asset',
        sub ($asset, $pooldir) {
            return {basename => 'path2', absolute_path => 'some/path2'};
        });
    my $cache_client_mock = _mock_cache_service_client \%fake_status;
    $cache_client_mock->redefine(asset_exists => 1);
    $cache_client_mock->redefine(asset_path => 'some/path2');
    $cache_client_mock->redefine(asset_request => Test::FakeRequest->new);

    my $error = 'not called';
    my $cb = sub ($err) { $error = $err; Mojo::IOLoop->stop };
    my $job = Test::FakeJob->new;
    my @assets = ('ISO_1');
    my $vars = {ISO_1 => 'FOO'};
    my @args = ($job, $vars, \@assets, {ISO_1 => 'iso'}, 'webuihost', undef, $cb);

    $cache_client_mock->redefine(enqueue => 0);

    OpenQA::Worker::Engines::isotovideo::cache_assets(OpenQA::CacheService::Client->new, @args);
    Mojo::IOLoop->start;
    is $vars->{ISO_1}, 'path2', 'path was correctly set';

    my $asset_uri = 'path2';
    $vars = {};
    my $status = OpenQA::CacheService::Response::Status->new(data => {});
    @args = (OpenQA::CacheService::Client->new, 'UEFI_PFLASH_VARS', $asset_uri, $status, $vars, undef, undef);
    is OpenQA::Worker::Engines::isotovideo::_handle_asset_processed(@args), undef, 'no error for UEFI_PFLASH_VARS';
    is $vars->{UEFI_PFLASH_VARS}, $asset_uri, 'specified asset URI set to vars';

    $args[1] = 'HDD_1';    # assume a normal asset (to not run into the special case of UEFI_PFLASH_VARS)
    $status->data->{has_download_error} = 1;    # assume download error
    $error = OpenQA::Worker::Engines::isotovideo::_handle_asset_processed(@args);
    is ref $error, 'HASH', 'error when download failed although asset is still existing'
      and is $error->{error}, 'Failed to download path2 to some/path2', 'expected error message returned';

    $status = OpenQA::CacheService::Response::Status->new(error => 'error');
    $args[1] = 'UEFI_PFLASH_VARS';
    delete $vars->{UEFI_PFLASH_VARS};
    is OpenQA::Worker::Engines::isotovideo::_handle_asset_processed(@args), undef, 'no error for UEFI_PFLASH_VARS';
    is $vars->{UEFI_PFLASH_VARS}, undef, 'asset URI not set because asset does not exist';
};

subtest 'syncing tests' => sub {
    my %fake_status = (status => 'processed', output => 'Fake rsync output', result => 'exit code 10');
    my $cache_client_mock = _mock_cache_service_client \%fake_status;
    $cache_client_mock->redefine(rsync_request => Test::FakeRequest->new(result => 'exit code 10'));

    my $worker = OpenQA::Test::FakeWorker->new;
    my $result = 'not called';
    my $cb = sub ($res) { $result = $res; Mojo::IOLoop->stop };
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
    is $result, 'cache-dir/webuihost/tests', 'returns synced test directory on success' or always_explain $result;
};

subtest 'symlink testrepo, logging behavior, variable expansion' => sub {
    my $pool_directory = tempdir('poolXXXX', TMPDIR => 1);
    my $worker = OpenQA::Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client = Test::FakeClient->new;

    subtest 'error case: CASEDIR missing' => sub {
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {DISTRI => 'foo'}});
        my $result = _run_engine($job);
        my $casedir = testcasedir('foo', undef, undef);
        like $result->{error}, qr/The source directory $casedir does not exist/,
          'symlink failed because the source directory does not exist';
    };

    subtest 'error case: permission denied' => sub {
        chmod(0444, $pool_directory);
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {DISTRI => 'opensuse'}});
        my $result = _run_engine($job);
        my $casedir = testcasedir('opensuse', undef, undef);
        like $result->{error},
          qr/Cannot create symlink from "$casedir" to "$pool_directory\/opensuse": Permission denied/,
          'symlink failed because permission denied';

    };
    chmod(0755, $pool_directory);

    subtest 'error case: NEEDLES_DIR missing' => sub {
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 12, settings => {NEEDLES_DIR => 'needles'}});
        my $result = _run_engine($job);
        my $casedir = testcasedir(undef, undef, undef);
        like $result->{error}, qr/The source directory $casedir\/needles does not exist/,
          'symlink needles directory failed because source directory does not exist';
    };

    subtest 'good case: direct invocation of helper function for symlinking' => sub {
        my $casedir = testcasedir('opensuse', undef, undef);
        my $result = OpenQA::Worker::Engines::isotovideo::_link_repo($casedir, $pool_directory, 'opensuse');
        is $result, undef, 'create symlink successfully';
    };

    my @custom_casedir_settings = (
        CASEDIR_DOMAIN => 'github.com',
        CASEDIR => 'https://%CASEDIR_DOMAIN%/foo/os-autoinst-distri-example.git#master',
        NEEDLES_DIR => 'fedora/needles',
        DISTRI => 'fedora',
        JOBTOKEN => 'token99916',
        _SECRET_TEST => 'secret-value',
        THE_PASSWORD => 'some-password',
    );

    subtest 'good case: custom CASEDIR and custom NEEDLES_DIR specified' => sub {
        my %job_settings = (id => 12, settings => {@custom_casedir_settings, NEEDLES_DIR => 'fedora/needles'});
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        my $log = combined_from { $result = _run_engine($job) };
        like $log,
          qr{Job settings.*Symlinked from "t/data/openqa/share/tests/fedora/needles" to "$pool_directory/needles"}s,
          'symlink for needles dir created, points to default dir despite custom CASEDIR';
        unlike $log, qr{secret-value.*some-password}s, 'no secrets logged';
        my $vars_data = get_job_json_data($pool_directory);
        my $casedir = testcasedir('fedora', undef, undef);
        is $vars_data->{PRODUCTDIR}, abs2rel(productdir('fedora', undef, undef), $casedir),
          'PRODUCTDIR still defaults to a relative path when CASEDIR is a URL to main.pm from custom test repo is used';
        is $vars_data->{NEEDLES_DIR}, 'needles', 'relative NEEDLES_DIR is set to its basename';
        is $result->{error}, undef, 'no error occurred (1)';
    };

    subtest 'good case: custom CASEDIR and custom NEEDLES_DIR specified and both are Git repos' => sub {
        my @needles_dir_settings = (NEEDLES_DIR => 'https://github.com/foo/os-autoinst-needles-example.git');
        my %job_settings = (id => 12, settings => {@custom_casedir_settings, @needles_dir_settings});
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        my $log = combined_from { $result = _run_engine($job) };
        unlike $log, qr/symlink/, 'no symlinks created';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{CASEDIR}, 'https://github.com/foo/os-autoinst-distri-example.git#master',
          'Git repo for casedir not changed';
        is $vars_data->{PRODUCTDIR}, undef, 'no default for PRODUCTDIR assigned';
        is $vars_data->{NEEDLES_DIR}, 'https://github.com/foo/os-autoinst-needles-example.git',
          'Git repo for needles not changed';
        is $result->{error}, undef, 'no error occurred (2)';
    };

    subtest 'good case: custom CASEDIR and NEEDLES_DIR where NEEDLES_DIR starts with %CASEDIR%' => sub {
        my %vars = (@custom_casedir_settings, NEEDLES_DIR => '%CASEDIR%/fedora/needles');
        my %job_settings = (id => 12, settings => \%vars);
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        my $log = combined_from { $result = _run_engine($job) };
        like $log,
          qr{Job settings.*Symlinked from "os-autoinst-distri-example/fedora/needles" to "$pool_directory/needles"}s,
          'symlink for needles dir created, %CASEDIR% replaced with checkout folder of custom CASEDIR';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{NEEDLES_DIR}, 'needles', 'relative NEEDLES_DIR is set to its basename';
        is $result->{error}, undef, 'no error occurred (3)';
    };

    subtest 'good case: custom CASEDIR specified but no custom NEEDLES_DIR' => sub {
        my %job_settings = (id => 12, settings => {@custom_casedir_settings});
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        combined_like { $result = _run_engine($job) }
        qr {Symlinked from "t/data/openqa/share/tests/fedora/needles" to "$pool_directory/needles"},
          'symlink for needles dir also created without NEEDLES_DIR, points to default dir despite custom CASEDIR';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{NEEDLES_DIR}, 'needles', 'relative NEEDLES_DIR is set to name of symlink';
        is $result->{error}, undef, 'no error occurred (4)';

    };

    subtest 'error case: custom CASEDIR specified, fail to symlink needles because cache directory does not exist' =>
      sub {
        my $isotovideo_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
        $isotovideo_mock->redefine(
            do_asset_caching => sub ($job, $vars, $cache_dir, $assetkeys, $webui_host, $pooldir, $callback) {
                my $shared_cache = catdir($cache_dir, base_host($webui_host));
                $callback->($shared_cache);
            });
        my %job_settings = (id => 16, settings => {@custom_casedir_settings});
        my $cache_dir = '/var/lib/openqa/cache/';
        $worker->settings->global_settings->{CACHEDIRECTORY} = $cache_dir;
        my $check_dir = $cache_dir . $client->webui_host . "/$job_settings{settings}->{DISTRI}" . '/needles';
        my ($job, $result) = OpenQA::Worker::Job->new($worker, $client, \%job_settings);
        $result = _run_engine($job);
        like $result->{error}, qr/The source directory $check_dir does not exist/,
          'the needledir is under the cache directory';
      };
};

subtest 'behavior with ABSOLUTE_TEST_CONFIG_PATHS=1' => sub {
    my $pool_directory = tempdir('poolXXXX', TMPDIR => 1);
    my $worker = OpenQA::Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client = Test::FakeClient->new;
    my @settings = (DISTRI => 'fedora', JOBTOKEN => 'token000', ABSOLUTE_TEST_CONFIG_PATHS => 1);

    subtest 'don\'t do symlink when job settings include ABSOLUTE_TEST_CONFIG_PATHS=1' => sub {
        my %settings = (@settings, HDD_1 => 'foo.qcow2');
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => \%settings});
        combined_unlike { _run_engine($job) }
        qr/Symlinked from/, 'don\'t do symlink when jobs have the ABSOLUTE_TEST_CONFIG_PATHS=1';
        my $vars_data = get_job_json_data($pool_directory);
        is $vars_data->{PRODUCTDIR}, productdir('fedora', undef, undef), 'default PRODUCTDIR assigned';
        is $vars_data->{CASEDIR}, testcasedir('fedora', undef, undef), 'default CASEDIR assigned';
        is $vars_data->{HDD_1}, locate_asset('hdd', 'foo.qcow2'),
          'don\'t symlink asset when using ABSOLUTE_TEST_CONFIG_PATHS=>1';
        is $vars_data->{NEEDLES_DIR}, undef, 'no NEEDLES_DIR assigned';
    };

    subtest 'absolute default NEEDLES_DIR with ABSOLUTE_TEST_CONFIG_PATHS=1 and custom CASEDIR' => sub {
        my %settings = (@settings, CASEDIR => 'git:foo/bar');
        my $job = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => \%settings});
        combined_unlike { _run_engine($job) }
        qr/Symlinked from/, 'don\'t do symlink when jobs have the ABSOLUTE_TEST_CONFIG_PATHS=1';
        my $vars_data = get_job_json_data($pool_directory);
        my $expected_productdir = abs2rel(productdir('fedora', undef, undef), testcasedir('fedora', undef, undef));
        is $vars_data->{NEEDLES_DIR}, needledir('fedora', undef, undef), 'default NEEDLES_DIR assigned';
        is $vars_data->{CASEDIR}, $settings{CASEDIR}, 'custom CASEDIR not touched';
        is $vars_data->{PRODUCTDIR}, $expected_productdir,
          'nevertheless relative PRODUCTDIR assigned to load main.pm from custom CASEDIR';
    };
};

subtest 'link asset' => sub {
    my $cwd = getcwd;
    my $pool_directory = tempdir('poolXXXX', TMPDIR => 1);
    my $worker = OpenQA::Test::FakeWorker->new(pool_directory => $pool_directory);
    my $client = Test::FakeClient->new;
    # just in case cleanup the symlink to really check if it gets re-created
    unlink 't/data/openqa/share/factory/hdd/symlink.qcow2' if -e 't/data/openqa/share/factory/hdd/symlink.qcow2';
    my $settings = {
        JOBTOKEN => 'token000',
        ISO => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
        HDD_1 => 'foo.qcow2',
        HDD_2 => 'symlink.qcow2',
        SYNC_ASSETS_HOOK => "ln -s foo.qcow2 $cwd/t/data/openqa/share/factory/hdd/symlink.qcow2"
    };
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 16, settings => $settings});
    combined_like { my $result = _run_engine($job) }
    qr/Linked asset/, 'linked asset';
    my $vars_data = get_job_json_data($pool_directory);
    my $orig_hdd = locate_asset('hdd', 'foo.qcow2');
    my $orig_iso = locate_asset('iso', 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso');
    my $linked_iso = "$pool_directory/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso";
    my $linked_hdd = "$pool_directory/foo.qcow2";
    my $linked_hdd2 = "$pool_directory/symlink.qcow2";
    ok -e $linked_iso, 'the iso is linked to pool directory';
    ok -e $linked_hdd, 'the hdd is linked to pool directory';
    ok -l $linked_hdd2, 'the hdd 2 is symlinked to pool directory';
    is((stat $linked_hdd)[1], (stat $orig_hdd)[1], 'hdd is hardlinked');
    is((stat $linked_iso)[1], (stat $orig_iso)[1], 'iso is hardlinked');
    is $vars_data->{ISO}, 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
      'the value of ISO is basename when doing link';
    is $vars_data->{HDD_1}, 'foo.qcow2', 'the value of HDD_1 is basename when doing link';
    unlink 't/data/openqa/share/factory/hdd/symlink.qcow2';
};

subtest 'using cgroupv2' => sub {
    my $file_mock = Test::MockModule->new('Mojo::File');
    $file_mock->noop('make_path');
    combined_like { OpenQA::Worker::Engines::isotovideo::_configure_cgroupv2({id => 42}) }
    qr|Using cgroup /sys/fs/cgroup/.*/42|, 'use of cgroup logged';
};

done_testing();
