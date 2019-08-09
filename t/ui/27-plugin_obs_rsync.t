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

use Mojo::Base -strict;

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);

OpenQA::Test::Case->new->init_data;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
EOF

my $t = Test::Mojo->new('OpenQA::WebAPI');

# needs to log in (it gets redirected)
$t->get_ok('/login');

$t->get_ok('/admin/obs_rsync')->status_is(200, "index status")->element_exists('a[href*="/admin/obs_rsync/Proj1"]');

$t->get_ok('/admin/obs_rsync/Proj1')->status_is(200, "project status")->element_exists('[rsync_iso.cmd]')
  ->element_exists('[rsync_repo.cmd]')->element_exists('[openqa.cmd]');

$t->get_ok('/admin/obs_rsync/Proj1/runs')->status_is(200, "project logs status")
  ->element_exists('[.run_190703_143010]');

$t->get_ok('/admin/obs_rsync/Proj1/runs/.run_190703_143010')->status_is(200, "project log subfolder status")
  ->element_exists('[files_iso.lst]');

$t->get_ok('/admin/obs_rsync/Proj1/runs/.run_190703_143010/download/files_iso.lst')
  ->status_is(200, "project log file download status")
  ->content_like(qr/openSUSE-Leap-15.1-DVD-x86_64-Build470.1-Media.iso/)
  ->content_like(qr/openSUSE-Leap-15.1-NET-x86_64-Build470.1-Media.iso/);

done_testing();
