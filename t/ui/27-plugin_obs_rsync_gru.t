# Copyright (C) 2019-2021 SUSE LLC
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
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

my ($t, $tempdir, $params) = setup_obs_rsync_test;
my $minion                 = $t->app->minion;

$t->post_ok('/admin/obs_rsync/Proj1/runs' => $params)->status_is(201, 'trigger rsync');
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/Proj1/, 'get project queue');

$t->get_ok('/admin/obs_rsync/Proj1/dirty_status')->status_is(200, 'get dirty status')->content_like(qr/dirty on/);
$t->post_ok('/admin/obs_rsync/Proj1/dirty_status' => $params)->status_is(200, 'dirty status update enqueued')
  ->content_like(qr/started/);
is $minion->jobs({tasks => [qw(obs_rsync_update_dirty_status)]})->total, 1, 'obs_rsync_update_dirty_status job enqueued';

$t->get_ok('/admin/obs_rsync/Proj1/obs_builds_text')->status_is(200, 'get builds text')->content_like(qr/No data/);
$t->post_ok('/admin/obs_rsync/Proj1/obs_builds_text' => $params)->status_is(200, 'builds text update enqueued')
  ->content_like(qr/started/);
is $minion->jobs({tasks => [qw(obs_rsync_update_builds_text)]})->total, 1, 'obs_rsync_update_builds_text job enqueued';

done_testing();
