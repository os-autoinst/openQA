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
use OpenQA::Utils;
use File::Copy;
use OpenQA::Test::Database;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use File::Which qw(which);
use File::Path qw();

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

sub create_temp_job_result_file {
    my ($resultdir) = @_;

    my $filename = $resultdir . '/autoinst-log.txt';
    open(my $fh, ">>", $filename) or die "touch $filename: $!\n";
    close $fh;
    die 'temporary file could not be created' unless -e $filename;
    return $filename;
}

my @jobs      = $t->app->db->resultset('Jobs')->search({state => 'done'})->all;
my $resultdir = $jobs[2]->result_dir;
my $jobid     = $jobs[2]->id;
my %args      = (resultdir => $resultdir, jobid => $jobid);

subtest 'reduce_result gru task cleans up logs' => sub {
    my $filename = create_temp_job_result_file($resultdir);
    run_gru('reduce_result' => \%args);
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

done_testing();
