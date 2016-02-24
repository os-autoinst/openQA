# Copyright (C) 2016 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

use t::ui::PhantomTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $get       = $t->get_ok('/tests/99946#previous')->status_is(200);
my $tab_label = $t->tx->res->dom->at('li a[href=#previous]')->all_text;
is($tab_label, q/Previous results (1)/, 'previous results with number is shown');
my $previous_results_header = $t->tx->res->dom->at('#previous #scenario')->all_text;
is($previous_results_header, q/Results for opensuse-13.1-DVD-i586-textmode, limited to 10/, 'header for previous results with scenario');
$get->element_exists('#res_99945',                'result from previous job');
$get->element_exists('#res_99945 .result_passed', 'previous job was passed');
my $build = $t->tx->res->dom->at('#previous #results .build')->all_text;
is($build, '0091', 'build of previous job is shown');
$get                     = $t->get_ok('/tests/99946?limit_previous=1#previous')->status_is(200);
$previous_results_header = $t->tx->res->dom->at('#previous #scenario')->all_text;
is($previous_results_header, q/Results for opensuse-13.1-DVD-i586-textmode, limited to 1/, 'can be limited with query parameter');

done_testing();
