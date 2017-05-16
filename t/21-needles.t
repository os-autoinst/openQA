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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Schema;
use OpenQA::Test::Database;

use File::Find;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my %settings = (
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
my $t = Test::Mojo->new('OpenQA::WebAPI');

sub process {
    return unless (m/.json$/);
    # add needle to database
    OpenQA::Schema::Result::Needles::update_needle($_, $module, 0);
}

# read needles from primary needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_fedora);
# read needles from another needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_archlinux);

my $rs  = $schema->resultset('Needles');
my $drs = $schema->resultset('NeedleDirs');

# there should be two files called test-rootneedle, that shouldn't be problem, because they have different needledir
is($rs->count({filename => "test-rootneedle.json"}), 2);
# there should be one test-rootneedle needle in fedora/needles needledir
is(
    $rs->search({filename => "test-rootneedle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# there should be one needle that has fedora/needles needledir and it has relative path in its filename
is(
    $rs->search({filename => "gnome/browser/test-nestedneedle-2.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# this tests that there can be two needles with the same names in different directories
is(
    $rs->search({filename => "test-duplicate-needle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
is(
    $rs->search({filename => "installer/test-duplicate-needle.json"})
      ->search_related('directory', {path => {like => '%fedora/needles'}})->count(),
    1
);
# this tests needledir for nested needles placed under non-project needledir
is(
    $rs->search({filename => "test-kdeneedle.json"})
      ->search_related('directory', {path => {like => '%archlinux/needles/kde'}})->count(),
    1
);
# all those needles should have file_present set to 1
if (my $needle = $rs->next) {
    is($needle->file_present, 1);
}

# create record in DB about non-existent needle
$rs->create(
    {
        dir_id                 => $drs->find({path => {like => '%fedora/needles'}})->id,
        filename               => "test-nonexistent.json",
        first_seen_module_id   => $module->id,
        last_seen_module_id    => $module->id,
        last_matched_module_id => $module->id,
        file_present           => 1
    });
# check that it was created
is($rs->count({filename => "test-nonexistent.json"}), 1);
# check that DB indicates that file is present
is($rs->find({filename => "test-nonexistent.json"})->file_present, 1);
# update info about whether needles are present
OpenQA::Schema::Result::Needles::scan_needles($t->app);
# this needle actually doesn't exist, so it should have file_present set to 0
is($rs->find({filename => "test-nonexistent.json"})->file_present, 0);
# this needle exists, so it should have file_present set to 1
is($rs->find({filename => "installer/test-nestedneedle-1.json"})->file_present, 1);

done_testing;
