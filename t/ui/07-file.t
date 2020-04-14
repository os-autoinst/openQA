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

use Mojo::Base -strict;

use FindBin;
use File::Spec;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Mojo::File;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# Exact size of logpackages-1.png
$t->get_ok('/tests/99938/images/logpackages-1.png')->status_is(200)->content_type_is('image/png')
  ->header_is('Content-Length' => '48019');

$t->get_ok('/tests/99937/../99938/images/logpackages-1.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/logpackages-1.png')->status_is(200)->content_type_is('image/png')
  ->header_is('Content-Length' => '6769');

# Not the same logpackages-1.png
$t->get_ok('/tests/99946/images/logpackages-1.png')->header_is('Content-Length' => '211');

$t->get_ok('/tests/99938/images/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/images/thumb/doesntexist.png')->status_is(404);

$t->get_ok('/tests/99938/file/video.ogv')->status_is(200)->content_type_is('video/ogg');

$t->get_ok('/tests/99938/file/serial0.txt')->status_is(200)->content_type_is('text/plain;charset=UTF-8');

$t->get_ok('/tests/99938/file/y2logs.tar.bz2')->status_is(200);

$t->get_ok('/tests/99938/file/ulogs/y2logs.tar.bz2')->status_is(404);

sub write_file {
    my ($path, $content) = @_;
    local $/;    # enable 'slurp' mode
    open my $fh, ">", $path;
    print $fh $content;
    close $fh;
}

subtest 'needle download' => sub {
    # clean leftovers from previous run
    my $needle_path     = 't/data/openqa/share/tests/opensuse/needles';
    my $abs_needle_path = File::Spec->rel2abs($needle_path);
    my $needle_dir      = Mojo::File->new($needle_path);
    $needle_dir->remove_tree();

    $t->get_ok('/needles/opensuse/inst-timezone-text.png')->status_is(404, '404 if image not present');
    $t->get_ok('/needles/1/image')->status_is(404, '404 if image not present');
    $t->get_ok('/needles/1/json')->status_is(404, '404 if json not present');

    # create fake json file and image
    $needle_dir->make_path();
    my $json
      = '{"area" : [{"height": 217, "type": "match", "width": 384, "xpos": 0, "ypos": 0},{"height": 60, "type": "exclude", "width": 160, "xpos": 175, "ypos": 45}], "tags": ["inst-timezone"]}';
    write_file("$needle_dir/inst-timezone-text.png",  "png\n");
    write_file("$needle_dir/inst-timezone-text.json", $json);

    # and another, in a subdirectory, to test that
    my $needle_subdir = Mojo::File->new('t/data/openqa/share/tests/opensuse/needles/subdirectory');
    $needle_subdir->make_path();
    my $json2
      = '{"area" : [{"height": 217, "type": "match", "width": 384, "xpos": 0, "ypos": 0},{"height": 60, "type": "exclude", "width": 160, "xpos": 175, "ypos": 45}], "tags": ["inst-subdirectory"]}';
    write_file("$needle_subdir/inst-subdirectory.png",  "png\n");
    write_file("$needle_subdir/inst-subdirectory.json", $json2);

    $t->get_ok('/needles/opensuse/inst-timezone-text.png')->status_is(200)->content_type_is('image/png')
      ->content_is("png\n");
    $t->get_ok('/needles/1/image')->status_is(200)->content_type_is('image/png')->content_is("png\n");
    $t->get_ok('/needles/1/json')->status_is(200)->content_type_is('application/json;charset=UTF-8')->content_is($json);

    # arguably this should work and be tested, but does not work now because
    # of how we do routing:
    #$t->get_ok('/needles/opensuse/subdirectory/inst-subdirectory.png')

    # currently you can only find a needle in a subdirectory by passing the
    # jsonfile query parameter like this:
    $t->get_ok("/needles/opensuse/inst-subdirectory.png?jsonfile=$needle_path/subdirectory/inst-subdirectory.json")
      ->status_is(200)->content_type_is('image/png')->content_is("png\n");
    # also test with jsonfile as absolute path (as usual in production)
    $t->get_ok("/needles/opensuse/inst-subdirectory.png?jsonfile=$abs_needle_path/subdirectory/inst-subdirectory.json")
      ->status_is(200)->content_type_is('image/png')->content_is("png\n");

  # getting needle image and json by ID also does not work for needles
  # in subdirectories, but arguably should do and should be tested:
  #$t->get_ok('/needles/2/image')->status_is(200)->content_type_is('image/png')->content_is("png\n");
  #$t->get_ok('/needles/2/json')->status_is(200)->content_type_is('application/json;charset=UTF-8')->content_is($json2);
};


# check the download links
$t->get_ok('/tests/99946/downloads_ajax')->status_is(200)->element_exists('#asset_1')->element_exists('#asset_5');
my $res = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#asset_1')->text);
is($res,                                     'openSUSE-13.1-DVD-i586-Build0091-Media.iso');
is($t->tx->res->dom->at('#asset_1')->{href}, '/tests/99946/asset/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso');
$res = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#asset_5')->text);
is($res,                                     'openSUSE-13.1-x86_64.hda');
is($t->tx->res->dom->at('#asset_5')->{href}, '/tests/99946/asset/hdd/openSUSE-13.1-x86_64.hda');

# downloads are currently redirects
$t->get_ok('/tests/99946/asset/1')->status_is(302)
  ->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/iso\/openSUSE-13.1-DVD-i586-Build0091-Media.iso/);
$t->get_ok('/tests/99946/asset/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso')->status_is(302)
  ->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/iso\/openSUSE-13.1-DVD-i586-Build0091-Media.iso/);

$t->get_ok('/tests/99946/asset/5')->status_is(302)
  ->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/hdd\/fixed\/openSUSE-13.1-x86_64.hda/);

# verify error on invalid downloads
$t->get_ok('/tests/99946/asset/iso/foobar.iso')->status_is(404);

$t->get_ok('/tests/99961/asset/repo/testrepo/README')->status_is(302)
  ->header_like(Location => qr/(?:http:\/\/localhost:\d+)?\/assets\/repo\/testrepo\/README/);
$t->get_ok('/tests/99961/asset/repo/testrepo/README/../README')->status_is(400)
  ->content_is('invalid character in path');

# download_asset is handled by apache normally, but make sure it works - important for fullstack test
$t->get_ok('/assets/repo/testrepo/README')->status_is(200);
$t->get_ok('/assets/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso')->status_is(200);
$t->get_ok('/assets/iso/../iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso')->status_is(404);
$t->get_ok('/assets/repo/testrepo/doesnotexist')->status_is(404);


# TODO: also test repos


SKIP: {
    skip "FIXME: allow to download only assets related to a test", 1;

    $t->get_ok('/tests/99946/asset/2')->status_is(400);
}

done_testing();
