# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

my ($t, $tempdir, $home, $params) = setup_obs_rsync_test;
my $app = $t->app;
my $minion = $app->minion;

{
    package FakeMinionJob;    # uncoverable statement count:2
    use Mojo::Base -base, -signatures;
    has id => 0;
    has app => sub { $app };
    sub finish { $_[0]->{state} = 'finished'; $_[0]->{result} = $_[1] }
    sub info { {notes => {project_lock => 1}} }
}

$t->post_ok('/admin/obs_rsync/Proj1/runs' => $params)->status_is(201, 'trigger rsync');
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/Proj1/, 'get project queue');

$t->get_ok('/admin/obs_rsync/Proj1/dirty_status')->status_is(200, 'get dirty status')->content_like(qr/dirty on/);
$t->post_ok('/admin/obs_rsync/Proj1/dirty_status' => $params)->status_is(200, 'dirty status update enqueued')
  ->content_like(qr/started/);
is $minion->jobs({tasks => [qw(obs_rsync_update_dirty_status)]})->total, 1,
  'obs_rsync_update_dirty_status job enqueued';

$t->get_ok('/admin/obs_rsync/Proj1/obs_builds_text')->status_is(200, 'get builds text')->content_like(qr/No data/);
$t->post_ok('/admin/obs_rsync/Proj1/obs_builds_text' => $params)->status_is(200, 'builds text update enqueued')
  ->content_like(qr/started/);
is $minion->jobs({tasks => [qw(obs_rsync_update_builds_text)]})->total, 1, 'obs_rsync_update_builds_text job enqueued';

subtest 'process minion jobs' => sub {
    my $minion_jobs = $minion->jobs;
    while (my $info = $minion_jobs->next) {
        my ($task, $job) = ($info->{task}, FakeMinionJob->new(app => $app));
        $minion->tasks->{$task}->($job, @{$info->{args}});
        $minion->job($info->{id})->remove;
        is $job->{state}, 'finished', "$task has been finished";
    }
    is $home->child('Proj1/files_iso.lst')->slurp, "openSUSE-Leap-15.1-DVD-x86_64-Build470.1-Media.iso\n",
      'files_iso.lst has been created';
};

done_testing();
