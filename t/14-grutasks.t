#!/usr/bin/env perl -w

# Copyright (c) 2016 SUSE LLC
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
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use File::Copy;
use OpenQA::Test::Database;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use File::Which 'which';
use File::Path ();
use Data::Dumper;
use Date::Format 'time2str';
use Fcntl ':mode';

# these are used to track assets being 'removed from disk' and 'deleted'
# by mock methods (so we don't *actually* lose them)
my @removed;
my @deleted;

# a mock 'delete' method for Assets which just appends the name to the
# @deleted array
sub mock_delete {
    my ($self) = @_;
    $self->remove_from_disk;
    push @deleted, $self->name;
}

# a mock 'remove_from_disk' which just appends the name to @removed
sub mock_remove {
    my ($self) = @_;
    push @removed, $self->name;
}

my $module = new Test::MockModule('OpenQA::Schema::Result::Assets');
$module->mock(delete           => \&mock_delete);
$module->mock(remove_from_disk => \&mock_remove);
$module->mock(refresh_size     => sub { });

my $schema     = OpenQA::Test::Case->new->init_data;
my $jobs       = $schema->resultset('Jobs');
my $job_groups = $schema->resultset('JobGroups');
my $assets     = $schema->resultset('Assets');

# refresh assets only once and prevent adding untracked assets
my $assets_mock = new Test::MockModule('OpenQA::Schema::ResultSet::Assets');
$schema->resultset('Assets')->refresh_assets();
$assets_mock->mock(scan_for_untracked_assets => sub { });
$assets_mock->mock(refresh_assets            => sub { });

my $t = Test::Mojo->new('OpenQA::WebAPI');

# now to something completely different: testing limit_assets
my $c = OpenQA::WebAPI::Plugin::Gru::Command::gru->new();
$c->app($t->app);

# list initially existing assets
my $dbh             = $schema->storage->dbh;
my $initial_aessets = $dbh->selectall_arrayref('select * from assets order by id;');
note('initially existing assets:');
note(Dumper($initial_aessets));

sub find_kept_assets_with_last_jobs {
    my $last_used_jobs = $assets->search(
        {
            -not => {
                -or => {
                    name            => {-in => \@removed},
                    last_use_job_id => undef
                },
            }
        },
        {
            order_by => {-asc => 'last_use_job_id'}});
    return [map { {asset => $_->name, job => $_->last_use_job_id} } $last_used_jobs->all];
}
is_deeply(find_kept_assets_with_last_jobs, [], 'initially, none of the assets has the job of its last use assigned');
is($job_groups->find(1001)->exclusively_kept_asset_size,
    undef, 'initially no size for exclusively kept assets accumulated');

sub run_gru {
    my ($task, $args) = @_;
    $t->app->gru->enqueue($task => $args);
    $c->run('run', '-o');
}

# understanding / revising these tests requires understanding the
# assets in the test database. As I write this, there are 6 assets
# in the Assets schema. assets 1, 2, 3, 4 and 5 are in job group 1001.
# assets 2 and 6 are in job group 1002. asset 5 is fixed, meaning
# limit_assets will see it but ignore it quite early on: it will
# never be deleted, nor will it ever be explicitly 'kept' and seen
# by the find_kept_assets_with_last_jobs query above (as it won't
# have a last_use_job_id).
#
# So essentially on each run through of limit_assets, it will first
# run through group 1001 and consider assets 3, 2, 1 and 4 in that
# order (as the most recent job associated with 4 is older than the
# most recent job associated with 1, and so on). Then it will run
# through group 1002 and consider assets 2 and 6 in that order. If
# group 1001 selects 2 for deletion, 1002 may cause it to be 'kept',
# but that is the only likely interaction between the groups.
#
# asset 2 is also associated with a running job, so even if it is
# scheduled for deletion after both groups 1001 and 1002 are checked,
# it should never actually get deleted.
#
# For this test we update the size of all assets to be 18 GiB
# so both groups should be under the size limit, and no deletion
# should occur.
my $gib = 1024 * 1024 * 1024;
$assets->update({size => 18 * $gib});
run_gru('limit_assets');

is_deeply(\@removed, [], "nothing should have been 'removed' at size 18GiB");
is_deeply(\@deleted, [], "nothing should have been 'deleted' at size 18GiB");

my @expected_last_jobs_no_removal = (
    {asset => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso', job => 99926},
    {asset => 'openSUSE-13.1-x86_64.hda',                                 job => 99946},
    {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',               job => 99947},
    {asset => 'testrepo',                                                 job => 99961},
    {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',             job => 99963},
    {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso',        job => 99981},
);

is_deeply(find_kept_assets_with_last_jobs, \@expected_last_jobs_no_removal, 'last jobs correctly assigned');

# 1001 should exclusively keep 3, 1, 5 and 4
is($job_groups->find(1001)->exclusively_kept_asset_size,
    72 * $gib, 'kept assets for group 1001 accumulated (18 GiB per asset)');
# 1002 should exclusively keep 2 and 6
is($job_groups->find(1002)->exclusively_kept_asset_size,
    36 * $gib, 'kept assets for group 1002 accumulated (18 GiB per asset)');


# at size 24GiB, group 1001 is over the 80% threshold but under the 100GiB
# limit - still no removal should occur.
$assets->update({size => 24 * $gib});
run_gru('limit_assets');

is_deeply(\@removed, [], "nothing should have been 'removed' at size 24GiB");
is_deeply(\@deleted, [], "nothing should have been 'deleted' at size 24GiB");

is_deeply(find_kept_assets_with_last_jobs, \@expected_last_jobs_no_removal, 'last jobs have not been altered');

# 1001 should exclusively keep the same as above
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    4 * 24 * $gib,
    'kept assets for group 1001 accumulated, job over threshold not taken into account (24 GiB per asset)'
);
# 1002 should exclusively keep the same as above
is(
    $job_groups->find(1002)->exclusively_kept_asset_size,
    2 * 24 * $gib,
    'kept assets for group 1002 accumulated (24 GiB per asset)'
);

# at size 26GiB, 1001 is over the limit, so removal should occur. Removing
# just one asset - #4 - will get under the 80GiB threshold.
$assets->update({size => 26 * $gib});
run_gru('limit_assets');

is(scalar @removed, 1, "one asset should have been 'removed' at size 26GiB");
is(scalar @deleted, 1, "one asset should have been 'deleted' at size 26GiB");

is_deeply(
    find_kept_assets_with_last_jobs,
    [
        {asset => 'openSUSE-13.1-x86_64.hda',                          job => 99946},
        {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',        job => 99947},
        {asset => 'testrepo',                                          job => 99961},
        {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',      job => 99963},
        {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso', job => 99981}
    ],
    'last jobs still present but first one deleted'
);

# 1001 should exclusively keep 3, 5 and 1
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    3 * 26 * $gib,
    'kept assets for group 1001 accumulated and deleted asset not taken into account (26 GiB per asset)'
);
# 1002 should exclusively keep 2 and 6
is(
    $job_groups->find(1002)->exclusively_kept_asset_size,
    2 * 26 * $gib,
    'kept assets for group 1002 accumulated (26 GiB per asset)'
);

# empty the tracking arrays before next test
@removed = ();
@deleted = ();

# at size 34GiB, 1001 is over the limit, so removal should occur.
$assets->update({size => 34 * $gib});
run_gru('limit_assets');

is(scalar @removed, 1, "two assets should have been 'removed' at size 34GiB");
is(scalar @deleted, 1, "two assets should have been 'deleted' at size 34GiB");

is_deeply(
    find_kept_assets_with_last_jobs,
    [
        {asset => 'openSUSE-13.1-x86_64.hda',                          job => 99946},
        {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',        job => 99947},
        {asset => 'testrepo',                                          job => 99961},
        {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',      job => 99963},
        {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso', job => 99981}
    ],
    'last jobs still present but first two deleted'
);

# 1001 should exclusively keep 1, 3 and 5
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    2 * 34 * $gib,
    'kept assets for group 1001 accumulated and deleted asset not taken into account (34 GiB per asset)'
);
# 1002 should exclusively keep 2 and 6
is(
    $job_groups->find(1002)->exclusively_kept_asset_size,
    2 * 34 * $gib,
    'kept assets for group 1002 accumulated (34 GiB per asset)'
);

# empty the tracking arrays before next test
@removed = ();
@deleted = ();

# now we set the most recent job for asset #1 (99947) to PENDING state,
# to test protection of assets for PENDING jobs which would otherwise
# be removed.
my $job99947 = $schema->resultset('Jobs')->find({id => 99947});
#$job99947->state(OpenQA::Jobs::Constants::SCHEDULED);
my $job99947_t_finished = $job99947->t_finished;
$job99947->update({t_finished => undef});

# Now we run again with size 34GiB. This time asset #1 should again be
# selected for removal, but reprieved at the last minute due to its
# association with a PENDING job.
run_gru('limit_assets');
is(scalar @removed, 1, "only one asset should have been 'removed' at size 34GiB with 99947 pending");
is(scalar @deleted, 1, "only one asset should have been 'deleted' at size 34GiB with 99947 pending");

# restore job 99947 to DONE state
#$job99947->state(OpenQA::Jobs::Constants::DONE);
#$job99947->update;
$job99947->update({t_finished => $job99947_t_finished});

sub create_temp_job_log_file {
    my ($resultdir) = @_;

    my $filename = $resultdir . '/autoinst-log.txt';
    open(my $fh, ">>", $filename) or die "touch $filename: $!\n";
    close $fh;
    die 'temporary file could not be created' unless -e $filename;
    return $filename;
}

subtest 'limit_results_and_logs gru task cleans up logs' => sub {
    my $job = $t->app->db->resultset('Jobs')->find(99937);
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    $job->group->update({"keep_logs_in_days" => 5});
    my $filename = create_temp_job_log_file($job->result_dir);
    run_gru('limit_results_and_logs');
    ok(!-e $filename, 'file got cleaned');
};

subtest 'migrate_images' => sub {
    File::Path::remove_tree('t/images/aa7/');
    File::Path::make_path('t/data/openqa/images/aa/.thumbs');
    copy(
        't/images/347/da6/.thumbs/61d0c3faf37d49d33b6fc308f2.png',
        't/data/openqa/images/aa/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png'
    );
    copy(
        't/images/347/da6/61d0c3faf37d49d33b6fc308f2.png',
        't/data/openqa/images/aa//7da661d0c3faf37d49d33b6fc308f2.png'
    );
    ok(!-l 't/data/openqa/images/aa/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png', 'no link yet');

    run_gru('migrate_images' => {prefix => 'aa'});
    ok(-l 't/data/openqa/images/aa/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png',  'now link');
    ok(-e 't/data/openqa/images/aa7/da6/.thumbs/61d0c3faf37d49d33b6fc308f2.png', 'file moved');

    File::Path::remove_tree('t/images/aa7/');
};

subtest 'relink_testresults' => sub {
    File::Path::make_path('t/data/openqa/images/34/.thumbs');
    symlink(
        '../../../images/347/da6/.thumbs/61d0c3faf37d49d33b6fc308f2.png',
        't/data/openqa/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png'
    );

    # setup
    unlink('t/data/openqa/testresults/00099/00099937-opensuse-13.1-DVD-i586-Build0091-kde/.thumbs/zypper_up-3.png');
    File::Path::make_path('t/data/openqa/testresults/00099937-opensuse-13.1-DVD-i586-Build0091-kde/.thumbs/');
    symlink('../../../../images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png',
        't/data/openqa/testresults/00099/00099937-opensuse-13.1-DVD-i586-Build0091-kde/.thumbs/zypper_up-3.png');
    like(
        readlink(
            't/data/openqa/testresults/00099/00099937-opensuse-13.1-DVD-i586-Build0091-kde/.thumbs/zypper_up-3.png'),
        qr{\Q/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png\E},
        'link correct'
    );

    run_gru('relink_testresults' => {max_job => 1000000, min_job => 0});
    like(
        readlink(
            't/data/openqa/testresults/00099/00099937-opensuse-13.1-DVD-i586-Build0091-kde/.thumbs/zypper_up-3.png'),
        qr{\Qimages/347/da6/.thumbs/61d0c3faf37d49d33b6fc308f2.png\E},
        'relinked'
    );
};

subtest 'rm_compat_symlinks' => sub {
    File::Path::make_path(join('/', $OpenQA::Utils::imagesdir, '34', '.thumbs'));
    symlink(
        '../../../images/347/da6/.thumbs/61d0c3faf37d49d33b6fc308f2.png',
        't/data/openqa/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png'
    );

    ok(-e 't/data/openqa/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png', 'thumb is there');
    run_gru('rm_compat_symlinks' => {});
    ok(!-e 't/data/openqa/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png', 'thumb is gone');
};

subtest 'human readable size' => sub {
    is(human_readable_size(13443399680), '13GiB',   'two digits GB');
    is(human_readable_size(8007188480),  '7.5GiB',  'smaller GB');
    is(human_readable_size(-8007188480), '-7.5GiB', 'negative smaller GB');
    is(human_readable_size(717946880),   '685MiB',  'large MB');
    is(human_readable_size(245760),      '240KiB',  'less than a MB');
};

subtest 'scan_images' => sub {
    is($t->app->db->resultset('Screenshots')->count, 0, "no screenshots in fixtures");
    run_gru('scan_images' => {prefix => '347'});
    is($t->app->db->resultset('Screenshots')->count, 1, "one screenshot found");

    run_gru('scan_images_links' => {min_job => 0, max_job => 100000});
    my @links = sort map { $_->job_id } $t->app->db->resultset('ScreenshotLinks')->all;
    is_deeply(\@links, [99937, 99938, 99940, 99946, 99962, 99963], "all links found");
};

subtest 'labeled jobs considered important' => sub {
    my $job = $t->app->db->resultset('Jobs')->find(99938);
    # but gets cleaned after important limit - change finished to 12 days ago
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    $job->group->update({"keep_logs_in_days"           => 5});
    $job->group->update({"keep_important_logs_in_days" => 20});
    my $filename = create_temp_job_log_file($job->result_dir);
    my $user = $t->app->db->resultset('Users')->find({username => 'system'});
    $job->comments->create({text => 'label:linked from test.domain', user_id => $user->id});
    run_gru('limit_results_and_logs');
    ok(-e $filename, 'file did not get cleaned');
    # but gets cleaned after important limit - change finished to 22 days ago
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 22, 'UTC')});
    run_gru('limit_results_and_logs');
    ok(!-e $filename, 'file got cleaned');
};

subtest 'Gru tasks limit' => sub {
    my $id  = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 1});
    my $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 1});
    ok defined $id, 'First task is scheduled';
    is $res, undef, 'No new job scheduled';
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'Second task is scheduled';
    $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    is $res, undef, 'Second task is not scheduled anymore';

    is $t->app->minion->backend->list_jobs(0, undef, {tasks => ['limit_assets'], states => ['inactive']})->{total}, 2;

    $c->run('run', '-o');
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'task is scheduled';
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'task is scheduled';
    $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    is $res, undef, 'Other tasks is not scheduled anymore';
    $c->run('run', '-o');
};

subtest 'Gru tasks TTL' => sub {
    $t->app->minion->reset;
    my $job_id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, ttl => -20});
    $c->run('run', '-o');
    my $result = $t->app->minion->job($job_id)->info->{result};
    is ref $result, 'HASH', 'We have a result' or diag explain $result;
    is $result->{error}, 'TTL Expired', 'TTL Expired - job discarded' or diag explain $result;

    $job_id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, ttl => 20});
    $c->run('run', '-o');
    $result = $t->app->minion->job($job_id)->info->{result};

    is ref $result, '', 'Result is the output';
    # Depending on logging options, gru task output can differ
    like $result, qr/Removing asset|Job successfully executed/i, 'TTL not Expired - Job executed'
      or diag explain $result;

    my @ids;
    for (1 .. 100) {
        push @ids, ($t->app->gru->enqueue(limit_assets => [] => {priority => 10, ttl => -50}))[0];
    }
    $c->run('run', '-o');

    is $t->app->minion->job($_)->info->{result}->{error}, 'TTL Expired', 'TTL Expired - job discarded' for @ids;

    my ($minion_id, $gru_id) = $t->app->gru->enqueue_limit_assets;
    ok $minion_id;
    ok $gru_id;
    isnt $minion_id, $gru_id;
};

SKIP: {
    skip 'no network available', 1 if $ENV{OBS_RUN};
    subtest 'download assets with correct permissions' => sub {
        # need to whitelist github
        $t->app->config->{global}->{download_domains} = 'github.com';

        my $assetsource = 'https://github.com/os-autoinst/os-autoinst/blob/master/t/data/Core-7.2.iso';
        my $assetpath   = 't/data/openqa/share/factory/iso/Core-7.2.iso';
        run_gru('download_asset' => [$assetsource, $assetpath, 0]);
        ok(-f $assetpath, 'asset downloaded');
        is(S_IMODE((stat($assetpath))[2]), 0644, 'asset downloaded with correct permissions');
    };
}

done_testing();
