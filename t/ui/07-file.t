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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

$t->get_ok('/tests/99938/images/logpackages-1.png')
    ->status_is(200)
    ->content_type_is('image/png')
    ->header_is('Content-Length' => '48019'); # Exact size of logpackages-1.png

$t->get_ok('/tests/99937/../99938/images/logpackages-1.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/logpackages-1.png')
    ->status_is(200)
    ->content_type_is('image/png')
    ->header_is('Content-Length' => '6769');

$t->get_ok('/tests/99946/images/logpackages-1.png')
    ->header_is('Content-Length' => '211'); # Not the same logpackages-1.png

$t->get_ok('/tests/99938/images/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/file/video.ogv')
    ->status_is(200)
    ->content_type_is('video/ogg');

$t->get_ok('/tests/99938/file/serial0.txt')
    ->status_is(200)
    ->content_type_is('text/plain;charset=UTF-8');

$t->get_ok('/tests/99938/file/y2logs.tar.bz2')->status_is(200);

$t->get_ok('/tests/99938/file/ulogs/y2logs.tar.bz2')->status_is(404);

$t->get_ok('/tests/99927/iso')
    ->status_is(200)
    ->header_is('Content-Disposition' => "attatchment; filename=openSUSE-13.1-DVD-i586-Build0091-Media.iso;");

#XXX this test assumes the opensuse needles are there
SKIP: {
skip "We need to fake tests are needles before running these tests", 7;

$t->get_ok('/needles/opensuse/inst-timezone.png')
    ->status_is(200)
    ->content_type_is('image/png');

$t->get_ok('/needles/opensuse/inst-timezone.json')
    ->status_is(200)
    ->content_type_is('application/json');

$t->get_ok('/needles/opensuse/doesntexist.png')->status_is(404);

}

done_testing();
