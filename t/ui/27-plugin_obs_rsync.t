# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

my ($t, $tempdir, $home, $params) = setup_obs_rsync_test;

sub _el {
    my ($project, $run, $file) = @_;
    return qq{a[href="/admin/obs_rsync/$project/runs/$run/download/$file"]} if $file;
    return qq{a[href="/admin/obs_rsync/$project/runs/$run"]} if $run;
    return qq{a[href="/admin/obs_rsync/$project"]};
}

sub _el1 {
    my ($project, $file) = @_;
    return _el($project, '.run_last', $file);
}

sub test_project {
    my ($t, $project, $batch, $dt, $build) = @_;
    $t->get_ok('/admin/obs_rsync')->status_is(200, 'index status')->element_exists(_el($project))
      ->content_unlike(qr/script\<\/a\>/);

    my $alias = $project;
    my $alias1 = $project;
    if ($batch) {
        $alias = "$project|$batch";
        $alias1 = $project . '%7C' . $batch;
        $t->get_ok("/admin/obs_rsync/$project")->status_is(200, 'parent project status')
          ->element_exists_not(_el1($project, 'rsync_iso.cmd'))->element_exists_not(_el1($project, 'rsync_repo.cmd'))
          ->element_exists_not(_el1($project, 'openqa.cmd'))->element_exists(_el($alias1));
    }

    $t->get_ok("/admin/obs_rsync/$alias")->status_is(200, 'project status')
      ->element_exists(_el1($alias1, 'rsync_iso.cmd'))->element_exists(_el1($alias1, 'rsync_repo.cmd'))
      ->element_exists(_el1($alias1, 'openqa.cmd'));

    $t->get_ok("/admin/obs_rsync/$alias/runs")->status_is(200, 'project logs status')
      ->element_exists(_el($alias1, ".run_$dt"));

    $t->get_ok("/admin/obs_rsync/$alias/runs/.run_$dt")->status_is(200, 'project log subfolder status')
      ->element_exists(_el($alias1, ".run_$dt", 'files_iso.lst'));

    $t->get_ok("/admin/obs_rsync/$alias/runs/.run_$dt/download/files_iso.lst")
      ->status_is(200, 'project log file download status')
      ->content_like(qr/openSUSE-Leap-15.1-DVD-x86_64-Build470.$build-Media.iso/)
      ->content_like(qr/openSUSE-Leap-15.1-NET-x86_64-Build470.$build-Media.iso/);

    $t->get_ok("/admin/obs_rsync/$alias/run_last")->status_is(200, 'get project last run')
      ->json_is('/message', $dt, 'run_last is $dt');

    $t->post_ok("/admin/obs_rsync/$alias/run_last" => $params)->status_is(200, 'forget project last run')
      ->json_is('/message', 'success', 'forgetting run_last succeeded');

    $t->get_ok("/admin/obs_rsync/$alias/run_last")->status_is(200, 'get project last run (after forgetting it)')
      ->json_is('/message', '', 'run_last is now empty');
}

subtest 'Smoke test Proj1' => sub {
    test_project($t, 'Proj1', '', '190703_143010_469.1', 1);
};

subtest 'Test batched project' => sub {
    test_project($t, 'BatchedProj', 'Batch1', '191216_150610', 2);
};

subtest 'Helper (not covered otherwise)' => sub {
    my $c = $t->app->build_controller;
    like ref $c->obs_rsync->guard('project'), qr/guard/i, 'guard helper returns guard';
};

done_testing();
