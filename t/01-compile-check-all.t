# Copyright (C) 2019 SUSE LLC
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
unshift @INC, "$FindBin::Bin/lib", "$FindBin::Bin/../lib";

use Test::Strict;
use Mojo::File;

$Test::Strict::TEST_SYNTAX   = 1;
$Test::Strict::TEST_STRICT   = 1;
$Test::Strict::TEST_WARNINGS = 1;

$Test::Strict::TEST_SKIP = [
    # skip test module which would require test API from os-autoinst to be present
    't/data/openqa/share/tests/opensuse/tests/installation/installer_timezone.pm',
    # problem: when tidy test fails - it leaves .tdy files, so we should ignore them
    Mojo::File->new->list_tree->grep(qr/\.tdy$/)->map('to_rel')->map('to_string')->to_array,
    # docker tests are in bash
    glob "t/docker/*.t",
];

all_perl_files_ok(qw(lib script t));
