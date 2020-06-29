# Copyright (C) 2014-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

#
# Very simple test to verify we end up on a useful page for old links
#
$t->get_ok('/tests/99938/modules/logpackages/steps/1')->status_is(302);
$t->header_like(Location => qr,(?:\Qhttp://localhost:\E\d+)?\Q/tests/99938#step/logpackages/1\E,);

done_testing();
