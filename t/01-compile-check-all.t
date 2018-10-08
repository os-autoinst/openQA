# Copyright (C) 2014 SUSE Linux Products GmbH
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

# require all modules to check if they even load

BEGIN {
    unshift @INC, 'lib';

    # FIXME: Requiring OpenQA::Worker::Cache::Services
    # Sets up Minion with Mojo::SQLite, that on DESTROY automatically disconnects from the database.
    # If the database is not existant or can't be accessed we get a warning, that translates to test failure.

    use Mojo::File 'tempdir';
    $ENV{CACHE_DIR} = tempdir;
}

use strict;
use warnings;
use Test::Compile;
my $test = Test::Compile->new();
$test->verbose(0);

my @files = $test->all_pm_files();
for my $file (@files) {
    $test->ok($test->pm_file_compiles($file), "Compile test for $file");
}

@files = $test->all_pl_files();
for my $file (@files) {
    $test->ok($test->pl_file_compiles($file), "Compile test for $file");
}
$test->done_testing();
