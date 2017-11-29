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
    push @deleted, $self->name;
}

# a mock 'remove_from_disk' which just appends the name to @removed
sub mock_remove {
    my ($self) = @_;
    push @removed, $self->name;
}

# a series of mock 'ensure_size' methods for the Assets class which
# return different sizes (in GiB), for testing limit_assets
sub mock_size_25 {
    return 25 * 1024 * 1024 * 1024;
}

sub mock_size_30 {
    return 30 * 1024 * 1024 * 1024;
}

sub mock_size_34 {
    return 34 * 1024 * 1024 * 1024;
}

sub mock_size_45 {
    return 45 * 1024 * 1024 * 1024;
}



my $module = new Test::MockModule('OpenQA::Schema::Result::Assets');
$module->mock(delete           => \&mock_delete);
$module->mock(remove_from_disk => \&mock_remove);

my $schema = OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');


# now to something completely different: testing limit_assets
my $c = OpenQA::WebAPI::Plugin::Gru::Command::gru->new();
$c->app($t->app);

sub run_gru {
    my ($task, $args) = @_;

    $t->app->gru->enqueue($task => $args);
    $c->run('run', '-o');
}

# default asset size limit is 100GiB. In our fixtures, we wind up with
# five JobsAssets, but one is fixed (and so should always be preserved)
# and one is the only one in its JobGroup and so will always be set to
# 'keep', so effectively we have three that may get deleted. If these
# tests start failing unexpectedly, check if the 'fixed' asset isn't being
# properly counted as such.

# So if each asset's 'size' is reported as 25GiB, we're under both
# the 100GiB limit and the 80% threshold, and no deletion should
# occur.
$module->mock(ensure_size => \&mock_size_25);
run_gru('limit_assets');

is_deeply(\@removed, [], "nothing should have been 'removed' at size 25GiB");
is_deeply(\@deleted, [], "nothing should have been 'deleted' at size 25GiB");

# at size 30GiB, we're over the 80% threshold but under the 100GiB limit
# still no removal should occur.
$module->mock(ensure_size => \&mock_size_30);
run_gru('limit_assets');

is_deeply(\@removed, [], "nothing should have been 'removed' at size 30GiB");
is_deeply(\@deleted, [], "nothing should have been 'deleted' at size 30GiB");

# at size 34GiB, we're over the limit, so removal should occur. Removing
# just one asset will get under the 80GiB threshold.
$module->mock(ensure_size => \&mock_size_34);
run_gru('limit_assets');

my $remsize = @removed;
my $delsize = @deleted;
is($remsize, 1, "one asset should have been 'removed' at size 34GiB");
is($delsize, 1, "one asset should have been 'deleted' at size 34GiB");

# empty the tracking arrays before next test
@removed = ();
@deleted = ();

# at size 45GiB, we're over the limit, so removal should occur. Removing
# one asset will not suffice to get under the 80GiB threshold, so *two*
# assets should be removed
$module->mock(ensure_size => \&mock_size_45);
run_gru('limit_assets');

$remsize = @removed;
$delsize = @deleted;
is($remsize, 2, "two assets should have been 'removed' at size 45GiB");
is($delsize, 2, "two assets should have been 'deleted' at size 45GiB");

# empty the tracking arrays before next test
@removed = ();
@deleted = ();

# set a job that uses asset 1 to a PENDING state. before we do this,
# only assets 2 and 6 in our fixtures are considered to be associated
# with PENDING jobs; there are other job fixtures in PENDING states
# which list other assets in their SETTINGS, but these fixtures don't
# have jobs_assets set. We could 'fix' that but it'd require rejigging
# all the above tests.
my $job99937 = $schema->resultset('Jobs')->find({id => 99937});
$job99937->state(OpenQA::Schema::Result::Jobs::SCHEDULED);
$job99937->update;
run_gru('limit_assets');

# Now only *one* asset should get removed, as asset 1 will be in the
# list of removal candidates, but will be protected by association
# with a pending job.
$remsize = @removed;
$delsize = @deleted;
is($remsize, 1, "one assets should have been 'removed' at size 45GiB with 99937 pending");
is($delsize, 1, "one assets should have been 'deleted' at size 45GiB with 99937 pending");

# restore job 99937 to DONE state
$job99937->state(OpenQA::Schema::Result::Jobs::DONE);
$job99937->update;

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
