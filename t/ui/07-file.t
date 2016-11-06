# Copyright (C) 2014-2016 SUSE LLC
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

use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# Exact size of logpackages-1.png
$t->get_ok('/tests/99938/images/logpackages-1.png')->status_is(200)->content_type_is('image/png')->header_is('Content-Length' => '48019');

$t->get_ok('/tests/99937/../99938/images/logpackages-1.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/logpackages-1.png')->status_is(200)->content_type_is('image/png')->header_is('Content-Length' => '6769');

# Not the same logpackages-1.png
$t->get_ok('/tests/99946/images/logpackages-1.png')->header_is('Content-Length' => '211');

$t->get_ok('/tests/99938/images/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/file/video.ogv')->status_is(200)->content_type_is('video/ogg');

$t->get_ok('/tests/99938/file/serial0.txt')->status_is(200)->content_type_is('text/plain;charset=UTF-8');

$t->get_ok('/tests/99938/file/y2logs.tar.bz2')->status_is(200);

$t->get_ok('/tests/99938/file/ulogs/y2logs.tar.bz2')->status_is(404);

$t->get_ok('/tests/99946/iso')->status_is(200)->header_is('Content-Disposition' => "attatchment; filename=openSUSE-13.1-DVD-i586-Build0091-Media.iso;");

# check the download links
my $req = $t->get_ok('/tests/99946')->status_is(200);
$req->element_exists('#downloads #asset_1');
$req->element_exists('#downloads #asset_5');
my $res = OpenQA::Test::Case::trim_whitespace($req->tx->res->dom->at('#downloads #asset_1')->text);
is($res,                                                  "openSUSE-13.1-DVD-i586-Build0091-Media.iso");
is($req->tx->res->dom->at('#downloads #asset_1')->{href}, '/tests/99946/asset/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso');
$res = OpenQA::Test::Case::trim_whitespace($req->tx->res->dom->at('#downloads #asset_5')->text);
is($res,                                                  "openSUSE-13.1-x86_64.hda");
is($req->tx->res->dom->at('#downloads #asset_5')->{href}, '/tests/99946/asset/hdd/openSUSE-13.1-x86_64.hda');

# downloads are currently redirects
$req = $t->get_ok('/tests/99946/asset/1')->status_is(302)->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/iso\/openSUSE-13.1-DVD-i586-Build0091-Media.iso/);
$req = $t->get_ok('/tests/99946/asset/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso')->status_is(302)->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/iso\/openSUSE-13.1-DVD-i586-Build0091-Media.iso/);

$req = $t->get_ok('/tests/99946/asset/5')->status_is(302)->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/hdd\/fixed\/openSUSE-13.1-x86_64.hda/);

# verify error on invalid downloads
$t->get_ok('/tests/99946/asset/iso/foobar.iso')->status_is(404);

$t->get_ok('/tests/99961/asset/repo/testrepo/README')->status_is(302)->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/repo\/testrepo\/README/);
$t->get_ok('/tests/99961/asset/repo/testrepo/README/../README')->status_is(400)->content_is('invalid character in path');

# verify 404 on download_assets - to be handled by apache (for now at least)
$t->get_ok('/assets/repo/testrepo/README')->status_is(404);
$t->get_ok('/assets/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso')->status_is(404);


# TODO: also test repos


SKIP: {
    skip "FIXME: allow to download only assets related to a test", 1;

    $req = $t->get_ok('/tests/99946/asset/2')->status_is(400);
}

done_testing();
