#! /usr/bin/perl

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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::MockModule;
use Test::Output qw(stdout_like);
use OpenQA::Test::Case;
use OpenQA::Task::Asset::Limit;

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# scan initially for untracked assets and refresh
my $schema = $t->app->schema;
$schema->resultset('Assets')->scan_for_untracked_assets();
$schema->resultset('Assets')->refresh_assets();

# prevent files being actually deleted
my $mock_asset = new Test::MockModule('OpenQA::Schema::Result::Assets');
my $mock_limit = new Test::MockModule('OpenQA::Task::Asset::Limit');
$mock_asset->mock(remove_from_disk          => sub { return 1; });
$mock_asset->mock(refresh_assets            => sub { });
$mock_asset->mock(scan_for_untracked_assets => sub { });
$mock_limit->mock(_remove_if                => sub { return 0; });

# define helper to prepare the returned asset status for checks
# * remove timestamps
# * split into assets without max_job and assets with max_job because the ones
#   without might occur in random order so tests shouldn't rely on it
sub prepare_asset_status {
    my ($asset_status) = @_;

    # ignore exact size of untracked assets since it depends on presence of other files (see %ignored_assets)
    my $groups = $asset_status->{groups};
    ok(delete $groups->{0}->{size},   'size of untracked assets');
    ok(delete $groups->{0}->{picked}, 'untracked assets picked');

    my $assets_with_max_job       = $asset_status->{assets};
    my $assets_with_max_job_count = 0;
    my %assets_without_max_job;
    for my $asset (@$assets_with_max_job) {
        my $name = $asset->{name};
        ok(delete $asset->{t_created}, "asset $name has t_created");

        # check that all assets which have no max_job at all are considered last
        if ($asset->{max_job}) {
            $assets_with_max_job_count += 1;
            fail('assets without max_job should go last') if (%assets_without_max_job);
            next;
        }

        # ignore 'Core-7.2.iso' and other assets which may or may not exist
        #  (eg. 'Core-7.2.iso' is downloaded conditionally in 14-grutasks.t)
        my %ignored_assets = (
            'iso/Core-7.2.iso'              => 1,
            'iso/whatever.iso'              => 1,
            'hdd/hdd_image2.qcow'           => 1,
            'hdd/hdd_image2.qcow2'          => 1,
            'hdd/00099963-hdd_image3.qcow2' => 1,
        );
        if ($ignored_assets{$name}) {
            next;
        }

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
        id            => undef,
        group         => 'Untracked',
        size_limit_gb => 0,
    },
    1001 => {
        id            => 1001,
        group         => 'opensuse',
        size_limit_gb => 100,
        size          => '107374182388',
        picked        => 12,
    },
    1002 => {
        id            => 1002,
        group         => 'opensuse test',
        size_limit_gb => 100,
        size          => '107374182384',
        picked        => 16,
    },
);
my @expected_assets_with_max_job = (
    {
        max_job     => 99981,
        type        => 'iso',
        pending     => 0,
        size        => 4,
        id          => 3,
        groups      => {1001 => 99981},
        name        => 'iso/openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso',
        fixed       => 0,
        picked_into => '1001',
    },
    {
        picked_into => 1002,
        name        => 'iso/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
        fixed       => 0,
        groups      => {1001 => 99963, 1002 => 99961},
        type        => 'iso',
        pending     => 1,
        id          => 2,
        size        => 4,
        max_job     => 99963,
    },
    {
        groups      => {1002 => 99961},
        name        => 'repo/testrepo',
        fixed       => 0,
        picked_into => '1002',
        max_job     => 99961,
        pending     => 1,
        id          => 6,
        type        => 'repo',
        size        => 12,
    },
    {
        name        => 'iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso',
        fixed       => 0,
        groups      => {1001 => 99947},
        picked_into => '1001',
        max_job     => 99947,
        pending     => 0,
        id          => 1,
        type        => 'iso',
        size        => 4,
    },
    {
        type        => 'hdd',
        pending     => 0,
        size        => 4,
        id          => 5,
        max_job     => 99946,
        picked_into => '1001',
        fixed       => 1,
        name        => 'hdd/fixed/openSUSE-13.1-x86_64.hda',
        groups      => {1001 => 99946},
    },
    {
        groups      => {1001 => 99926},
        fixed       => 0,
        name        => 'iso/openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso',
        picked_into => '1001',
        max_job     => 99926,
        type        => 'iso',
        pending     => 0,
        id          => 4,
        size        => 0,
    },
);
my %expected_assets_without_max_job = (
    'hdd/fixed/Fedora-25.img' => {
        picked_into => 0,
        groups      => {},
        fixed       => 1,
        pending     => 0,
        type        => 'hdd',
        size        => 0,
        max_job     => undef,
    },
    'hdd/openSUSE-12.2-x86_64.hda' => {
        picked_into => 0,
        groups      => {},
        fixed       => 0,
        pending     => 0,
        type        => 'hdd',
        size        => 0,
        max_job     => undef,
    },
    'hdd/openSUSE-12.3-x86_64.hda' => {
        max_job     => undef,
        pending     => 0,
        type        => 'hdd',
        size        => 0,
        fixed       => 0,
        groups      => {},
        picked_into => 0,
    },
    'hdd/Windows-8.hda' => {
        max_job     => undef,
        type        => 'hdd',
        pending     => 0,
        size        => 0,
        fixed       => 0,
        groups      => {},
        picked_into => 0,
    },
    'hdd/openSUSE-12.1-x86_64.hda' => {
        max_job     => undef,
        type        => 'hdd',
        pending     => 0,
        size        => 0,
        fixed       => 0,
        groups      => {},
        picked_into => 0,
    },
);

subtest 'asset status with pending state, max_job and max_job by group' => sub {
    my $asset_status = $schema->resultset('Assets')->status(
        compute_pending_state_and_max_job => 1,
        compute_max_job_by_group          => 1,
    );
    my ($assets_with_max_job, $assets_without_max_job) = prepare_asset_status($asset_status);
    is_deeply($asset_status->{groups}, \%expected_groups,                 'groups');
    is_deeply($assets_with_max_job,    \@expected_assets_with_max_job,    'assets with max job');
    is_deeply($assets_without_max_job, \%expected_assets_without_max_job, 'assets without max job');
};

subtest 'asset status without pending state, max_job and max_job by group' => sub {
    # execute OpenQA::Task::Asset::Limit::_limit() so the last_use_job_id column of the asset table
    # is populated and so the order of the assets should be the same as in the previous subtest
    OpenQA::Task::Asset::Limit::_limit($t->app);

    # adjust expected assets
    for my $asset (@expected_assets_with_max_job) {
        $asset->{pending} = undef;
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
        compute_max_job_by_group          => 0,
    );
    my ($assets_with_max_job, $assets_without_max_job) = prepare_asset_status($asset_status);
    is_deeply($assets_with_max_job,    \@expected_assets_with_max_job,    'assets with max job');
    is_deeply($assets_without_max_job, \%expected_assets_without_max_job, 'assets without max job');
};

subtest 'limit for keeping untracked assets is overridable in settings' => sub {
    stdout_like(
        sub {
            OpenQA::Task::Asset::Limit::_limit($t->app);
        },
        qr/Asset .* is not in any job group, will delete in 14 days/,
        'default is 14 days'
    );

    $t->app->config->{misc_limits}->{untracked_assets_storage_duration} = 2;
    stdout_like(
        sub {
            OpenQA::Task::Asset::Limit::_limit($t->app);
        },
        qr/Asset .* is not in any job group, will delete in 2 days/,
        'override works'
    );
};

done_testing();
