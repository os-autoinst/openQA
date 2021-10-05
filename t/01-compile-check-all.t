# Copyright 2019-2020 SUSE LLC
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

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '400';

use Test::Strict;

push @Test::Strict::MODULES_ENABLING_STRICT,   'Test::Most';
push @Test::Strict::MODULES_ENABLING_WARNINGS, 'Test::Most';

$Test::Strict::TEST_SYNTAX   = 1;
$Test::Strict::TEST_STRICT   = 1;
$Test::Strict::TEST_WARNINGS = 1;
$Test::Strict::TEST_SKIP     = [
    # skip test module which would require test API from os-autoinst to be present
    't/data/openqa/share/tests/opensuse/tests/installation/installer_timezone.pm',
    # Skip data files which are supposed to resemble generated output which has no 'use' statements
    't/data/40-templates.pl',
    't/data/40-templates-more.pl',
    't/data/openqa-trigger-from-obs/Proj2::appliances/.api_package',
    't/data/openqa-trigger-from-obs/Proj2::appliances/.dirty_status',
    't/data/openqa-trigger-from-obs/Proj3::standard/empty.txt',
];
all_perl_files_ok(qw(lib script t));
