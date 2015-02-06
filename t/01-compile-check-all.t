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
}

use strict;
use warnings;
use Test::Compile;
my $test = Test::Compile->new();
$test->verbose(0);

my @files = $test->all_pm_files();
for my $file (@files) {
    #TODO: JobModules and Schema fail to compile for some reason
    #error "Attempt to load_namespaces() failed" because of OpenQA::Scheduler in JobModules
    next if ($file =~ /JobModules\.pm|Schema\.pm/);
    $test->ok($test->pm_file_compiles($file), "Compile test for $file");
}
$test->done_testing();
