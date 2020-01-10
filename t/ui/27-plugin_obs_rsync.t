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

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);
use File::Copy::Recursive 'dircopy';

OpenQA::Test::Case->new->init_data;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";
dircopy($home_template, $home);
$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
EOF

my $t = Test::Mojo->new('OpenQA::WebAPI');

# needs to log in (it gets redirected)
$t->get_ok('/login');

BAIL_OUT('Login exit code (' . $t->tx->res->code . ')') if $t->tx->res->code != 302;

sub _el {
    my ($project, $run, $file) = @_;
    return qq{a[href="/admin/obs_rsync/$project/runs/$run/download/$file"]} if $file;
    return qq{a[href="/admin/obs_rsync/$project/runs/$run"]}          if $run;
    return qq{a[href="/admin/obs_rsync/$project"]};
}

sub _el1 {
    my ($project, $file) = @_;
    return _el($project, '.run_last', $file);
}

sub test_project {
    my ($t, $project, $batch, $dt) = @_;
    $t->get_ok('/admin/obs_rsync')->status_is(200, 'index status')->element_exists(_el($project))
      ->content_unlike(qr/script\<\/a\>/);

    my $projectbatch  = $project;
    my $projectbatch1 = $project;
    if ($batch) {
        $projectbatch  = "$project|$batch";
        $projectbatch1 = $project . '%7C' . $batch;
        $t->get_ok("/admin/obs_rsync/$project")->status_is(200, 'project status')
          ->element_exists_not(_el1($project, 'rsync_iso.cmd'))->element_exists_not(_el1($project, 'rsync_repo.cmd'))
          ->element_exists_not(_el1($project, 'openqa.cmd'))->element_exists(_el($projectbatch1));
    }

    $t->get_ok("/admin/obs_rsync/$projectbatch")->status_is(200, 'project status')
      ->element_exists(_el1($projectbatch1, 'rsync_iso.cmd'))->element_exists(_el1($projectbatch1, 'rsync_repo.cmd'))
      ->element_exists(_el1($projectbatch1, 'openqa.cmd'));

    $t->get_ok("/admin/obs_rsync/$projectbatch/runs")->status_is(200, 'project logs status')
      ->element_exists(_el($projectbatch1, ".run_$dt"));

    $t->get_ok("/admin/obs_rsync/$projectbatch/runs/.run_$dt")->status_is(200, 'project log subfolder status')
      ->element_exists(_el($projectbatch1, ".run_$dt", 'files_iso.lst'));

    $t->get_ok("/admin/obs_rsync/$projectbatch/runs/.run_$dt/download/files_iso.lst")
      ->status_is(200, "project log file download status")
      ->content_like(qr/openSUSE-Leap-15.1-DVD-x86_64-Build470.1-Media.iso/)
      ->content_like(qr/openSUSE-Leap-15.1-NET-x86_64-Build470.1-Media.iso/);
}

subtest 'Smoke test Proj1' => sub {
    test_project($t, 'Proj1', '', '190703_143010');
};

subtest 'Test batched project' => sub {
    test_project($t, 'BatchedProj', 'Batch1', '191216_150610');
};

done_testing();
