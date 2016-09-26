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

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $get       = $t->get_ok('/tests/99946#previous')->status_is(200);
my $tab_label = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('li a[href=#previous]')->all_text);
is($tab_label, q/Previous results (2)/, 'previous results with number is shown');
my $previous_results_header = $t->tx->res->dom->at('#previous #scenario .h5');
like(OpenQA::Test::Case::trim_whitespace($previous_results_header->all_text), qr/Results for opensuse-13.1-DVD-i586-textmode/, 'header for previous results with scenario');
$get->element_exists('#res_99945',                    'result from previous job');
$get->element_exists('#res_99945 .result_passed',     'previous job was passed');
$get->element_exists('#res_99944 .result_softfailed', 'previous job was passed (softfailed)');
like($t->tx->res->dom->at('#res_99944 ~ .build a')->{href}, qr{/tests/overview?}, 'build links to overview page');
my $build = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#previous_results .build')->all_text);
is($build, '0091', 'build of previous job is shown');
$get = $t->get_ok($previous_results_header->at('a')->{href})->status_is(200);
is($t->tx->res->dom->at('#info_box .panel-heading a')->{href}, '/tests/99947', 'latest link points to last in scenario');
$get = $t->get_ok('/tests/99946?limit_previous=1#previous')->status_is(200);
my $table_rows = $t->tx->res->dom->find('#previous tbody tr');
is($table_rows->size, 1, 'can be limited with query parameter');
my $more_results = $t->tx->res->dom->at('#previous #more_results');
my $res          = OpenQA::Test::Case::trim_whitespace($more_results->all_text);
is($res, q{Limit to 10 / 20 / 50 / 100 / 400 previous results}, 'more results can be requested');
my $limit_url = $more_results->find('a[href]')->last->{href};
like($limit_url, qr/limit_previous=400/, 'limit URL includes limit');
like($limit_url, qr/arch=i586/,          'limit URL includes architecture');
like($limit_url, qr/flavor=DVD/,         'limit URL includes flavour');
like($limit_url, qr/test=textmode/,      'limit URL includes test');
like($limit_url, qr/version=13.1/,       'limit URL includes version');
like($limit_url, qr/machine=32bit/,      'limit URL includes machine');
like($limit_url, qr/distri=opensuse/,    'limit URL includes distri');
$get = $t->get_ok($limit_url)->status_is(200);
$res = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#previous #more_results b')->all_text);
like($res, qr/400/, 'limited to the selected number');
$get = $t->get_ok('/tests/99939')->status_is(200);
$get->element_exists_not('#res_99936', 'does not show jobs of different scenario (different machine)');

done_testing();
