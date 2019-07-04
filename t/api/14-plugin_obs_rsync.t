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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Mojo::File qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;
use File::Basename;
use Mojo::File qw(tempdir path);

# we must create db, otherwise OpenQA::WebAPI will try to (unused in test)
my $db = OpenQA::Test::Database->new->create(skip_fixtures => 1);

# this test also serves to test plugin loading via config file
my @conf = (
    "[global]\n",    "plugins=ObsRsync::Plugin\n",
    "[obs_rsync]\n", "home=" . dirname(__FILE__) . "/../data/openqa-trigger-from-obs\n"
);
my $tempdir = tempdir;
$ENV{OPENQA_CONFIG} = $tempdir;
path($ENV{OPENQA_CONFIG})->make_path->child("openqa.ini")->spurt(@conf);

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);


ok($t->get_ok('/admin/plugin/obs_rsync/')->status_is(200), "index status");
ok($t->tx->res->content->body_contains('Leap:15.1'),       "index content");

ok($t->get_ok('/admin/plugin/obs_rsync/Leap:15.1:ToTest')->status_is(200), "project status");
ok($t->tx->res->content->body_contains('rsync_iso.cmd'),                   "rsync iso commands");
ok($t->tx->res->content->body_contains('rsync_repo.cmd'),                  "rsync repo commands");
ok($t->tx->res->content->body_contains('openqa.cmd'),                      "openqa commands");

ok($t->get_ok('/admin/plugin/obs_rsync/Leap:15.1:ToTest/runs')->status_is(200), "project logs status");
ok($t->tx->res->content->body_contains('.run_190703_143010'),                   "project logs folder");

ok($t->get_ok('/admin/plugin/obs_rsync/Leap:15.1:ToTest/runs/.run_190703_143010')->status_is(200),
    "project log subfolder status");
ok($t->tx->res->content->body_contains('files_iso.lst'), "project log file");

ok(
    $t->get_ok('/admin/plugin/obs_rsync/Leap:15.1:ToTest/runs/.run_190703_143010/download/files_iso.lst')
      ->status_is(200),
    "project log file download status"
);
ok($t->tx->res->content->body_contains('openSUSE-Leap-15.1-DVD-x86_64-Build470.1-Media.iso'),
    "project log file download content");
ok($t->tx->res->content->body_contains('openSUSE-Leap-15.1-NET-x86_64-Build470.1-Media.iso'),
    "project log file download content");


ok($t->put_ok('/admin/plugin/obs_rsync/Leap:15.1:ToTest/runs')->status_is(201), "trigger rsync");
ok($t->put_ok('/admin/plugin/obs_rsync/WRONGPROJECT/runs')->status_is(404),     "trigger rsync wrong project");

done_testing();
