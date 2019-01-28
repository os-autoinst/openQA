#!/usr/bin/env perl -w

# Copyright (C) 2016 Red Hat
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

use strict;
use warnings;

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Schema;
use OpenQA::Test::Database;
use OpenQA::Task::Needle::Scan;
use File::Find;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Date::Format 'time2str';

my %settings = (
    TEST    => 'test',
    DISTRI  => 'fedora',
    FLAVOR  => 'DVD',
    VERSION => '25',
    BUILD   => '20160916',
    ISO     => 'whatever.iso',
    MACHINE => 'alpha',
    ARCH    => 'x86_64',
);

my $schema              = OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $needledir_archlinux = "t/data/openqa/share/tests/archlinux/needles";
my $needledir_fedora    = "t/data/openqa/share/tests/fedora/needles";
# create dummy job
my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
# create dummy module
my $module = $job->insert_module({name => "a", category => "a", script => "a", flags => {}});
my $t      = Test::Mojo->new('OpenQA::WebAPI');

sub process {
    return unless (m/.json$/);
    # add needle to database
    OpenQA::Schema::Result::Needles::update_needle($_, $module, 0);
}

# read needles from primary needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_fedora);
# read needles from another needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_archlinux);

my $needles     = $schema->resultset('Needles');
my $needle_dirs = $schema->resultset('NeedleDirs');

# there should be two files called test-rootneedle, that shouldn't be problem, because they have different needledir
is($needles->count({filename => "test-rootneedle.json"}), 2);

subtest 'handling of last update' => sub {
    is($needles->count({last_updated => undef}), 0, 'all needles should have last_updated set');

    my $needle = $needles->find(
        {
            filename         => 'test-rootneedle.json',
            'directory.path' => {-like => '%' . $needledir_archlinux},
        },
        {prefetch => 'directory'});
    is($needle->last_updated, $needle->t_created, 'last_updated initialized on creation');

    # fake timestamps to be in the past to observe a difference if the test runs inside the same wall-clock second
    my $seconds_per_day = 60 * 60 * 24;
    $needle->update(
        {
            t_created    => time2str('%Y-%m-%dT%H:%M:%S', time - ($seconds_per_day * 5)),
            last_updated => time2str('%Y-%m-%dT%H:%M:%S', time - ($seconds_per_day * 5)),
            t_updated    => time2str('%Y-%m-%dT%H:%M:%S', time - ($seconds_per_day * 2.5)),
        });

    $needle->discard_changes;
    my $t_created          = $needle->t_created;
    my $t_updated          = $needle->t_updated;
    my $last_actual_update = $needle->last_updated;
    my $new_last_match     = time2str('%Y-%m-%dT%H:%M:%S', time);

    $needle->update({last_matched_time => $new_last_match});

    $needle->discard_changes;
    is($needle->last_updated, $t_created, 'last_updated not altered');
    ok($t_updated lt $needle->t_updated, 't_updated still updated');
    is($needle->last_matched_time, $new_last_match, 'last match updated');

    my $other_needle
      = $needles->update_needle_from_editor($needle->directory->path, 'test-rootneedle', {tags => [qw(foo bar)]},);
    is($other_needle->dir_id,   $needle->dir_id,   "directory hasn't changed");
    is($other_needle->filename, $needle->filename, "filename hasn't changed");
    is($other_needle->id,       $needle->id,       "updated the same needle");

    $needle->discard_changes;
    my $last_actual_update2 = $needle->last_updated;
    ok(
        $last_actual_update lt $last_actual_update2,
        "last_updated changed after updating needle from editor ($last_actual_update < $last_actual_update2)",
    );
};

# there should be one test-rootneedle needle in fedora/needles needledir
is(
    $needles->search({filename => "test-rootneedle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# there should be one needle that has fedora/needles needledir and it has relative path in its filename
is(
    $needles->search({filename => "gnome/browser/test-nestedneedle-2.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# this tests that there can be two needles with the same names in different directories
is(
    $needles->search({filename => "test-duplicate-needle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
is(
    $needles->search({filename => "installer/test-duplicate-needle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# this tests needledir for nested needles placed under non-project needledir
is(
    $needles->search({filename => "test-kdeneedle.json"})
      ->search_related('directory', {path => {like => '%archlinux/needles/kde'}})->count(),
    1
);
# all those needles should have file_present set to 1
if (my $needle = $needles->next) {
    is($needle->file_present, 1);
}

# create record in DB about non-existent needle
$needles->create(
    {
        dir_id                 => $needle_dirs->find({path => {like => '%fedora/needles'}})->id,
        filename               => "test-nonexistent.json",
        last_seen_module_id    => $module->id,
        last_matched_module_id => $module->id,
        file_present           => 1
    });
# check that it was created
is($needles->count({filename => "test-nonexistent.json"}), 1);
# check that DB indicates that file is present
is($needles->find({filename => "test-nonexistent.json"})->file_present, 1);
# update info about whether needles are present
OpenQA::Task::Needle::Scan::_needles($t->app);
# this needle actually doesn't exist, so it should have file_present set to 0
is($needles->find({filename => "test-nonexistent.json"})->file_present, 0);
# this needle exists, so it should have file_present set to 1
is($needles->find({filename => "installer/test-nestedneedle-1.json"})->file_present, 1);

done_testing;
