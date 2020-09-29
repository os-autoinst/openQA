# Copyright (C) 2016-2020 SUSE LLC
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
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub verify_navbar {
    my ($expected) = @_;
    $t->get_ok('/')->status_is(200);
    my $groups = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('.navbar-nav li.dropdown')->all_text);
    # in fixtures both are sort_order 0, so they are sorted by name
    is($groups, "Job Groups $expected", "got $expected");
}

# in fixtures both are sort_order 0, so they are sorted by name
verify_navbar("opensuse opensuse test");

# move 'opensuse' to a higher sort order (further down)
$t->app->schema->resultset('JobGroups')->find(1001)->update({sort_order => 1});
verify_navbar("opensuse test opensuse");

# move 'opensuse test' to an even higher sort order (further down)
$t->app->schema->resultset('JobGroups')->find(1002)->update({sort_order => 3});
verify_navbar("opensuse opensuse test");

# create a new parent group - default sort order, no children
my $parent = $t->app->schema->resultset('JobGroupParents')->create({name => 'Hallo'});
# it's not shown (no children)
verify_navbar("opensuse opensuse test");

# create a child - it appears at position 0
$parent->children->create({name => 'New Jobs'});
verify_navbar("Hallo New Jobs opensuse opensuse test");

# now move in between the groups
$parent->update({sort_order => 2});
verify_navbar("opensuse Hallo New Jobs opensuse test");

done_testing();
