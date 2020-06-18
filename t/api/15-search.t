#!/usr/bin/env perl
# Copyright (C) 2017-2020 SUSE LLC
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
use Test::Mojo;

use FindBin;
use lib "$FindBin::Bin/../lib";
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(skip_fixtures => 1);
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'Perl modules' => sub {
    $t->get_ok('/api/v1/experimental/search?q=timezone', 'search successful');
    $t->json_is('/error'  => undef,                                                               'no errors');
    $t->json_is('/data/0' => {occurrence => 'opensuse/tests/installation/installer_timezone.pm'}, 'module found');
    $t->json_is(
        '/data/1' => {
            occurrence => 'opensuse/tests/installation/installer_timezone.pm',
            contents   => qq{    assert_screen "inst-timezone", 125 || die 'no timezone';}
        },
        'contents found'
    );
};

subtest 'Errors' => sub {
    $t->get_ok('/api/v1/experimental/search', 'Search succesful');
    $t->json_is('/error' => 'Erroneous parameters (q missing)', 'no search terms results in error');

    $t->get_ok('/api/v1/experimental/search?q=*', 'wildcard is interpreted literally');
    $t->json_is('/data' => [], 'no result for *');

    $t->app->config->{rate_limits}->{search} = 3;
    $t->get_ok('/api/v1/experimental/search?q=timezone', 'Search succesful') for (1 .. 3);
    $t->json_is('/error' => 'Rate limit exceeded', 'rate limit triggered');
};

done_testing();
