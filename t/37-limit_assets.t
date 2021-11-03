#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::File 'path';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Time::Seconds;
use Test::Output qw(stdout_like stdout_from);
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Task::Asset::Limit;
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry);
use OpenQA::Utils qw(:DEFAULT assetdir);
use OpenQA::WebAPI::Controller::API::V1::Iso;

{
    package Test::FakeJob;
    use Mojo::Base -base;
    has app => undef;
    has fail => undef;
    has retry => undef;
    has note => undef;
}

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 05-job_modules.pl 06-job_dependencies.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
my $schema = $app->schema;
my $assets = $schema->resultset('Assets');

# assume some assets already have a last_use_job_id
$assets->find($_)->update({last_use_job_id => 99963}) for (2, 3);

note('Asset directory: ' . assetdir());

subtest 'configurable concurrency' => sub {
    my $fake_job = Test::FakeJob->new(app => $app);
    my $guard = acquire_limit_lock_or_retry($fake_job);
    like ref $guard, qr/guard/i, 'guard returned by default';
    is $fake_job->retry, undef, 'no retry attempted';
    is 0, acquire_limit_lock_or_retry($fake_job), 'zero returned if lock already acquired';
    is_deeply $fake_job->retry, {delay => ONE_MINUTE}, 'retry triggered';
    $app->config->{cleanup}->{concurrent} = 1;
    is 1, acquire_limit_lock_or_retry($fake_job), 'returns truthy value if concurrency enabled';
};

subtest 'filesystem removal' => sub {
    my $asset_sub_dir = path(assetdir(), 'foo');
    $asset_sub_dir->make_path;

    subtest 'remove file' => sub {
        my $asset_path = path($asset_sub_dir, 'foo.txt');
        $asset_path->spurt('foo');
        stdout_like { $assets->create({type => 'foo', name => 'foo.txt', size => 3})->delete }
        qr/removed $asset_path/, 'removal logged';
        ok(!-e $asset_path, 'asset is gone');
    };
    subtest 'remove directory tree' => sub {
        my $asset_path = path($asset_sub_dir, 'some-repo');
        $asset_path->make_path;
        path($asset_path, 'repo-file')->spurt('a file within the repo');
        stdout_like { $assets->create({type => 'foo', name => 'some-repo', size => 3})->delete }
        qr/removed $asset_path/, 'removal logged';
        ok(!-e $asset_path, 'asset is gone');
    };
    subtest 'removal skipped' => sub {
        stdout_like { $assets->create({type => 'foo', name => 'some-repo', size => 3})->delete }
        qr/skipping removal of foo\/some-repo/, 'skpping logged';
    };
};

# ensure Core-7.2.iso exists (usually created by t/14-grutasks.t anyways)
my $core72iso_path = assetdir() . '/iso/Core-7.2.iso';
Mojo::File->new($core72iso_path)->spurt('foo') unless (-f $core72iso_path);

# scan initially for untracked assets and refresh
$schema->resultset('Assets')->scan_for_untracked_assets();
$schema->resultset('Assets')->refresh_assets();

# prevent files from actually being deleted
my $mock_asset = Test::MockModule->new('OpenQA::Schema::Result::Assets');
my $mock_limit = Test::MockModule->new('OpenQA::Task::Asset::Limit');
$mock_asset->redefine(remove_from_disk => sub { return 1; });
$mock_asset->mock(refresh_assets => sub { });
$mock_limit->redefine(_remove_if => sub { return 0; });

# define a fix asset_size_limit configuration for this test to be independent of the default value
# we possibly want to adjust without going into the details of this test (the test t/36-job_group_settings.t
# is covering defaults)
$app->config->{default_group_limits}->{asset_size_limit} = 100;

# move group 1002 into a parent group
$schema->resultset('JobGroupParents')->create({id => 1, name => 'parent of "opensuse test"', size_limit_gb => 100});
$schema->resultset('JobGroups')->search({id => 1002})->update({parent_id => 1});

# define helper to prepare the returned asset status for checks
# * remove timestamps
# * split into assets without max_job and assets with max_job because the ones
#   without might occur in random order so tests shouldn't rely on it
sub prepare_asset_status {
    my ($asset_status) = @_;

    # ignore exact size of untracked assets since it depends on presence of other files (see %ignored_assets)
    my $groups = $asset_status->{groups};
    is_deeply([sort keys %$groups], [0, 1001, 1002], 'groups present');
    ok(delete $groups->{0}->{size}, 'size of untracked assets');
    ok(delete $groups->{0}->{picked}, 'untracked assets picked');

    my $assets_with_max_job = $asset_status->{assets};
    my $assets_with_max_job_count = 0;
    my %assets_without_max_job;
    for my $asset (@$assets_with_max_job) {
        my $name = $asset->{name};
        ok(delete $asset->{t_created}, "asset $name has t_created");

        # check that all assets which have no max_job at all are considered last
        if ($asset->{max_job}) {
            $assets_with_max_job_count += 1;
            fail('assets without max_job should go last') if keys %assets_without_max_job;
            next;
        }

        # other tests may be clobbering the assets folder depending on order of execution
        my %assets_under_test = (
            'hdd/Windows-8.hda' => 1,
            'hdd/fixed/Fedora-25.img' => 1,
            'hdd/openSUSE-12.1-x86_64.hda' => 1,
            'hdd/openSUSE-12.2-x86_64.hda' => 1,
            'hdd/openSUSE-12.3-x86_64.hda' => 1,
        );
        next unless $assets_under_test{$name};

        ok(delete $asset->{id}, "asset $name has ID");
        $assets_without_max_job{delete $asset->{name}} = $asset;
    }
    splice(@$assets_with_max_job, $assets_with_max_job_count);

    return ($assets_with_max_job, \%assets_without_max_job);
}

# define groups and assets we expect to be present
# note: If this turns out to be too hard to maintain, we can shrink it later to only a few samples.
my %expected_groups = (
    0 => {
        id => undef,
        parent_id => undef,
        group => 'Untracked',
        size_limit_gb => 0,
    },
    1001 => {
        id => 1001,
        parent_id => undef,
        group => 'opensuse',
        size_limit_gb => 100,
        size => '107374182388',
        picked => 12,    # assets belonging to parentless job group are accounted directly to that job group
    },
    1002 => {
        id => 1002,
        parent_id => '1',
        group => 'parent of "opensuse test" / opensuse test',
        size_limit_gb => 100,
        size => '107374182400',
        picked => 0,    # the assets not supposed to be accounted here but only to the parent group
    },
);
my %expected_parents = (
    1 => {
        id => '1',
        group => 'parent of "opensuse test"',
        size_limit_gb => 100,
        size => '107374182384',
        picked => 16,    # the assets of its only child group 1002 are supposed to be accounted here
    },
);
my @expected_assets_with_max_job = (
    {
        max_job => 99981,
        last_job => 99963,    # assigned in test setup; deviates from max_job on purpose
        type => 'iso',
        pending => 0,
        size => 4,
        id => 3,
        groups => {1001 => 99981},
        parents => {},
        name => 'iso/openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso',
        fixed => 0,
        picked_into => '1001',
    },
    {
        picked_into => 1002,
        picked_into_parent_id => 1,
        name => 'iso/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
        fixed => 0,
        groups => {1001 => 99963, 1002 => 99961}
        ,    # specific job groups still visible when a job group is within a parent group
        parents => {1 => 1},
        type => 'iso',
        pending => 1,
        id => 2,
        size => 4,
        max_job => 99963,
        last_job => 99963,    # assigned in test setup
    },
    {
        groups => {1002 => 99961},    # specific job groups still visible when a job group is within a parent group
        parents => {1 => 1},
        name => 'repo/testrepo',
        fixed => 0,
        picked_into => '1002',
        picked_into_parent_id => 1,
        max_job => 99961,
        pending => 1,
        id => 6,
        type => 'repo',
        size => 12,
        last_job => undef,
    },
    {
        name => 'iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso',
        fixed => 0,
        groups => {1001 => 99947},
        parents => {},
        picked_into => '1001',
        max_job => 99947,
        pending => 0,
        id => 1,
        type => 'iso',
        size => 4,
        last_job => undef,
    },
    {
        type => 'hdd',
        pending => 0,
        size => 4,
        id => 5,
        max_job => 99946,
        picked_into => '1001',
        fixed => 1,
        name => 'hdd/fixed/openSUSE-13.1-x86_64.hda',
        groups => {1001 => 99946},
        parents => {},
        last_job => undef,
    },
    {
        groups => {1001 => 99938},
        fixed => 0,
        id => undef,    # ID might vary
        max_job => 99938,
        name => 'iso/openSUSE-Factory-DVD-x86_64-Build0048-Media.iso',
        parents => {},
        pending => 0,
        picked_into => '1001',
        size => undef,    # non-existing asset, pulled in by registering assets from settings of job 99938
        type => 'iso',
        last_job => undef,
    },
    {
        groups => {1001 => 99926},
        parents => {},
        fixed => 0,
        name => 'iso/openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso',
        picked_into => '1001',
        max_job => 99926,
        type => 'iso',
        pending => 0,
        id => 4,
        size => undef,    # non-existing asset, explicitely defined in fixtures (01-jobs.pl)
        last_job => undef,
    },
);
my %expected_assets_without_max_job = (
    'hdd/fixed/Fedora-25.img' => {
        picked_into => 0,
        groups => {},
        parents => {},
        fixed => 1,
        pending => 0,
        type => 'hdd',
        size => 0,
        max_job => undef,
        last_job => undef,
    },
    'hdd/openSUSE-12.2-x86_64.hda' => {
        picked_into => 0,
        groups => {},
        parents => {},
        fixed => 0,
        pending => 0,
        type => 'hdd',
        size => 0,
        max_job => undef,
        last_job => undef,
    },
    'hdd/openSUSE-12.3-x86_64.hda' => {
        max_job => undef,
        last_job => undef,
        pending => 0,
        type => 'hdd',
        size => 0,
        fixed => 0,
        groups => {},
        parents => {},
        picked_into => 0,
    },
    'hdd/Windows-8.hda' => {
        max_job => undef,
        last_job => undef,
        type => 'hdd',
        pending => 0,
        size => 0,
        fixed => 0,
        groups => {},
        parents => {},
        picked_into => 0,
    },
    'hdd/openSUSE-12.1-x86_64.hda' => {
        max_job => undef,
        last_job => undef,
        type => 'hdd',
        pending => 0,
        size => 0,
        fixed => 0,
        groups => {},
        parents => {},
        picked_into => 0,
    },
);

subtest 'tracked assets' => sub {
    my @assets = $schema->resultset('Assets')->search;
    my @tracked_assets;
    for my $asset (@assets) {
        push @tracked_assets, $asset->type . '/' . $asset->name;
    }
    # Assets here include non-iso in iso, files in other, CURRENT repos
    for my $name (qw(iso/whatever.sha256 other/misc.xml repo/otherrepo-CURRENT)) {
        ok(-e assetdir() . '/' . $name, "$name exists in the test folder");
        ok(grep(/$name$/, @tracked_assets), "$name picked up for cleanup")
          || diag explain join(' ', sort @tracked_assets);
    }
    # Ignored assets include repo links, file links
    for my $name (qw(repo/somethingrepo other/misc2.xml)) {
        ok(-e assetdir() . '/' . $name, "$name exists in the test folder");
        ok(!grep(/$name$/, @tracked_assets), "$name ignored") || diag explain join(' ', sort @tracked_assets);
    }
};

my $empty_asset_id;
subtest 'handling assets with invalid name' => sub {
    my $asset_count = $schema->resultset('Assets')->count;

    # check whether registering an asset with empty name is prevented
    is($schema->resultset('Assets')->register(repo => ''), undef, 'registering an empty asset prevented');

    # handling within OpenQA::Schema::Result::Jobs::register_assets_from_settings
    my $job = $schema->resultset('Jobs')->first;
    my $job_settings = $job->{_settings} = {REPO_0 => ''};
    stdout_like { $job->register_assets_from_settings() }
    qr/not registering asset with empty name or type/,
      'warning on attempt to register asset with empty name/type from settings';
    $job_settings->{REPO_0} = 'in/valid';
    stdout_like { $job->register_assets_from_settings() }
    qr/not registering asset in\/valid containing \//,
      'warning on attempt to register asset with invalid name from settings';
    is($schema->resultset('Assets')->count, $asset_count, 'no further assets registered');

    # add an asset with empty name nevertheless to test that it is ignored (in subsequent subtest)
    my $empty_asset = $schema->resultset('Assets')->create({type => 'repo', name => ''});
    ok($empty_asset, 'asset with empty name registered (to test ignoring it)');
    $empty_asset_id = $empty_asset->id;
};

subtest 'asset registration considers chained and directly chained parent jobs' => sub {
    # mock locate_asset function to track which assets are considered by the registration function
    my @located_assets;
    my $utils_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
    $utils_mock->redefine(
        locate_asset => sub {
            push @located_assets, $_[1];
            return 0;
        });

    # assume there's one chained parent
    my $expected_asset_base_name = 'openSUSE-Factory-DVD-x86_64-Build0048-Media.iso';
    my @expected_assets = map { $_ . $expected_asset_base_name } ('00099937-', '');
    my $child_job = $schema->resultset('Jobs')->find(99938);
    $child_job->register_assets_from_settings;
    is_deeply(\@located_assets, \@expected_assets, 'chained parent considered') or diag explain \@located_assets;

    # assume there's one directly chained parent
    @located_assets = ();
    $child_job->parents->update({dependency => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED});
    $child_job->discard_changes;
    $child_job->register_assets_from_settings;
    is_deeply(\@located_assets, \@expected_assets, 'directly chained parent considered')
      or diag explain \@located_assets;

    # assume there's one parallel parent
    @located_assets = ();
    $child_job->parents->update({dependency => OpenQA::JobDependencies::Constants::PARALLEL});
    $child_job->discard_changes;
    $child_job->register_assets_from_settings;
    is_deeply(\@located_assets, [$expected_asset_base_name], 'parallel parent not considered')
      or diag explain \@located_assets;
};

subtest 'asset status with pending state, max_job and max_job by group' => sub {
    my $asset_status;
    stdout_like {
        $asset_status = $schema->resultset('Assets')->status(
            compute_pending_state_and_max_job => 1,
            compute_max_job_by_group => 1,
        )
    }
    qr/Skipping asset $empty_asset_id because its name is empty/, 'warning about skipped asset';
    my ($assets_with_max_job, $assets_without_max_job) = prepare_asset_status($asset_status);
    $assets_with_max_job->[5]->{id} = undef;    # might vary
    is_deeply($asset_status->{groups}, \%expected_groups, 'groups');
    is_deeply($asset_status->{parents}, \%expected_parents, 'parents');
    is_deeply($assets_with_max_job, \@expected_assets_with_max_job, 'assets with max job');
    is_deeply($assets_without_max_job, \%expected_assets_without_max_job, 'assets without max job');
};

subtest 'asset status without pending state, max_job and max_job by group' => sub {
    my $job = Test::FakeJob->new(app => $app);

    # execute OpenQA::Task::Asset::Limit::_limit() so the last_use_job_id column of the asset table
    # is populated and so the order of the assets should be the same as in the previous subtest
    OpenQA::Task::Asset::Limit::_limit($app, $job);
    is($job->fail, undef, 'job did not fail');

    # adjust expected assets
    for my $asset (@expected_assets_with_max_job) {
        $asset->{pending} = undef;
        $asset->{last_job} = undef;
        my $groups = $asset->{groups};
        for my $group_id (keys %$groups) {
            $groups->{$group_id} = undef;
        }
    }
    for my $asset_name (keys %expected_assets_without_max_job) {
        my $asset = $expected_assets_without_max_job{$asset_name};
        $asset->{pending} = undef;
    }

    my $asset_status = $schema->resultset('Assets')->status(
        compute_pending_state_and_max_job => 0,
        compute_max_job_by_group => 0,
    );
    my ($assets_with_max_job, $assets_without_max_job) = prepare_asset_status($asset_status);
    $assets_with_max_job->[5]->{id} = undef;    # might vary
    is_deeply($assets_with_max_job, \@expected_assets_with_max_job, 'assets with max job')
      or diag explain $assets_with_max_job;
    is(
        join(' ', sort keys %$assets_without_max_job),
        join(' ', sort keys %expected_assets_without_max_job),
        'assets without max job'
    );
};

subtest 'size of exclusively kept assets tracked' => sub {
    my @groups = ($schema->resultset('JobGroups')->all, $schema->resultset('JobGroupParents')->all);
    my %exclusively_kept_assets = map { $_->id => $_->exclusively_kept_asset_size } @groups;
    is_deeply(
        \%exclusively_kept_assets,
        {
            '1001' => 12,
            '1002' => 0,    # value not present because 1002 is in parent group 1
            '1' => 16,    # everything from 1002
        }) or diag explain \%exclusively_kept_assets;
};

subtest 'limit for keeping untracked assets is overridable in settings' => sub {
    my $job = Test::FakeJob->new(app => $app);

    stdout_like { OpenQA::Task::Asset::Limit::_limit($app, $job) }
    qr/Asset .* is not in any job group and will be deleted in 14 days/, 'default is 14 days';

    $app->config->{misc_limits}->{untracked_assets_storage_duration} = 2;
    stdout_like { OpenQA::Task::Asset::Limit::_limit($app, $job) }
    qr/Asset .* is not in any job group and will be deleted in 2 days/, 'override works';
    is($job->fail, undef, 'job did not fail');
    # Reset limit to default
    $app->config->{misc_limits}->{untracked_assets_storage_duration} = 14;
};

subtest 'limits based on fine-grained filename-based patterns' => sub {
    my $job = Test::FakeJob->new(app => $app);
    # Reset mtime to the current time
    for my $filename (qw(iso/Core-7.2.iso hdd/openSUSE-12.2-x86_64.hda hdd/openSUSE-12.3-x86_64.hda)) {
        my $fullpath = Mojo::File->new(assetdir(), $filename)->to_abs;
        ok(utime(time, time, $fullpath), "Reset mtime of $filename");
    }

    stdout_like { OpenQA::Task::Asset::Limit::_limit($app, $job) }
    qr/Asset .+Core-.+ is not in any job group and will be deleted in 14 days/, 'default without pattern is 14 days';

    $app->config->{'assets/storage_duration'}->{'Core-'} = 30;
    $app->config->{'assets/storage_duration'}->{'openSUSE.+x86_64'} = 10;
    my $stdout = stdout_from(sub { OpenQA::Task::Asset::Limit::_limit($app, $job); });
    is($job->fail, undef, 'job did not fail');
    like($stdout, qr/Asset .+Core-.+ will be deleted in 30 days/, 'simple pattern override works');
    like($stdout, qr/Asset .+openSUSE-12\.2-x86_64.+ will be deleted in 10 days/, 'regex pattern matches 12.2');
    like($stdout, qr/Asset .+openSUSE-12\.3-x86_64.+ will be deleted in 10 days/, 'regex pattern matches 12.3');

    # Half-way into the limit the remaining time is shorter
    my $now = DateTime->now->add(DateTime::Duration->new(days => 15, end_of_month => 'wrap'));
    my $mock_datetime = Test::MockModule->new('DateTime');
    $mock_datetime->redefine(now => sub { return $now; });
    $stdout = stdout_from(sub { OpenQA::Task::Asset::Limit::_limit($app, $job); });
    is($job->fail, undef, 'job did not fail');
    like($stdout, qr/Asset .+Core-.+ will be deleted in 15 days/, 'simple pattern half-way in');

    # mtime is newer than the time of registration
    my $mtime = $now->add(DateTime::Duration->new(days => 3, end_of_month => 'wrap'));
    utime $mtime->epoch, $mtime->epoch, Mojo::File->new($core72iso_path)->to_abs;
    $stdout = stdout_from(sub { OpenQA::Task::Asset::Limit::_limit($app, $job); });
    is($job->fail, undef, 'job did not fail');
    like($stdout, qr/Asset .+Core-.+ will be deleted in 12 days/, 'newer mtime takes precedence');

    # Drop non-default pattern limits
    delete $app->config->{'assets/storage_duration'}->{'Core-'};
    delete $app->config->{'assets/storage_duration'}->{'openSUSE.+x86_64'};
};

subtest 'error handling' => sub {
    my $assets_mock = Test::MockModule->new('OpenQA::Schema::ResultSet::Assets');

    subtest 'key constraint violation' => sub {
        my $job = Test::FakeJob->new(app => $app);
        $assets_mock->redefine(
            status => sub {
                die 'insert or update on table "assets" violates foreign key constraint "assets_fk_last_use_job_id"';
            });
        OpenQA::Task::Asset::Limit::_limit($app, $job);
        is_deeply($job->retry, {delay => 60}, 'job will be tried again in a minute');
        is($job->fail, undef, 'job not failed');
    };

    subtest 'unknown error' => sub {
        my $job = Test::FakeJob->new(app => $app);
        $assets_mock->redefine(status => sub { die 'strange error' });
        OpenQA::Task::Asset::Limit::_limit($app, $job);
        is($job->retry, undef, 'job not retried on unknown error');
        like($job->fail, qr/strange error/, 'job fails on unknown error');
    };
};

done_testing();
