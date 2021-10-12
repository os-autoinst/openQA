# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '50';
use Mojo::IOLoop;
use OpenQA::Test::Utils 'perform_minion_jobs';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

my %config = (concurrency => 2, queue_limit => 2, retry_interval => 1);
my ($t, $tempdir, $home) = setup_obs_rsync_test(fixtures_glob => '01-jobs.pl 03-users.pl', config => \%config);
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# just check that all projects are mentioned
$t->get_ok('/api/v1/obs_rsync')->status_is(200, 'project list')->content_like(qr/Proj1/)->content_like(qr/Proj2/)
  ->content_like(qr/Proj3/)->content_unlike(qr/Proj3::standard/)->content_like(qr/BatchedProj/);

subtest 'smoke' => sub {
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "trigger rsync");
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')->status_is(404, "trigger rsync wrong project");
    $t->put_ok('/admin/obs_rsync/Proj1/runs')->status_is(404, "trigger rsync non-api path");
    $t->put_ok('/api/v1/obs_rsync/Proj3/runs?repository=standard')->status_is(201, "trigger with repository parameter");
};

perform_minion_jobs($t->app->minion);

subtest 'appliances' => sub {
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=images')->status_is(201, "trigger with repository parameter");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=images')
      ->status_is(208, "trigger with repository parameter again");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=appliances')
      ->status_is(201, "trigger with different repository");
};

perform_minion_jobs($t->app->minion);

sub test_queue {
    my $t = shift;
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=wrong')
      ->status_is(204, "Proj2 with different repository ignored");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=images')
      ->status_is(201, "Proj2 first time - should just start as queue is empty");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs')
      ->status_is(208, "Proj2 second time - should report IN_QUEUE, because another Proj2 wasn't started by worker");
    $t->put_ok('/api/v1/obs_rsync/Proj3::standard/runs')->status_is(201, "Proj3 first time - should just start");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs')->status_is(208, "Proj2 still gets queued");
    $t->put_ok('/api/v1/obs_rsync/Proj3::standard/runs')->status_is(208, "Proj3 now reports that already queued");
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs?repository=standard')
      ->status_is(507, "Proj1 cannot be handled because queue is full 2=(Proj2, Proj3 running)");
    $t->put_ok('/api/v1/obs_rsync/Proj3/runs?repository=standard')->status_is(208, "Proj3 is still in queue");
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')->status_is(404, "wrong project still returns error");

    perform_minion_jobs($t->app->minion);

    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "Proj1 just starts as queue is empty now");
}

subtest 'test queue' => sub {
    test_queue($t);
};
perform_minion_jobs($t->app->minion);

subtest 'test queue again' => sub {
    test_queue($t);
};

perform_minion_jobs($t->app->minion);

my $helper = $t->app->obs_rsync;

subtest 'latest_test' => sub {
    is($helper->get_last_test_id('Proj1'), 99937);
    $t->get_ok('/api/v1/obs_rsync/Proj1/latest_test')->status_is(200, 'status')->content_like(qr/99937/, 'correct id')
      ->content_unlike(qr/passed/)->json_like('/id' => qr/^99937$/)->json_hasnt('/result');
    $t->get_ok('/api/v1/obs_rsync/Proj1/latest_test?full=1')->status_is(200, 'status')
      ->content_like(qr/99937/, 'correct id')->content_like(qr/passed/)->json_like('/id' => qr/^99937$/)
      ->json_has('/result')->json_like('/result' => qr/^passed$/);
};

subtest 'test_result' => sub {
    is($helper->get_version_test_id('Proj1', '468.2'), 99926);
    is($helper->get_version_test_id('Proj1', '469.1'), 99937);

    $t->get_ok('/api/v1/obs_rsync/Proj1/test_result?version=468.2')->status_is(200, 'status')
      ->content_like(qr/99926/, 'correct id')->content_unlike(qr/passed/)->content_unlike(qr/incomplete/)
      ->json_like('/id' => qr/^99926$/)->json_hasnt('/result');
    $t->get_ok('/api/v1/obs_rsync/Proj1/test_result?version=468.2&full=1')->status_is(200, 'status')
      ->content_like(qr/99926/, 'correct id')->content_unlike(qr/passed/)->content_like(qr/incomplete/)
      ->json_like('/id' => qr/^99926$/)->json_has('/result')->json_like('/result' => qr/^incomplete$/);
    $t->get_ok('/api/v1/obs_rsync/Proj1/test_result?version=469.1')->status_is(200, 'status')
      ->content_like(qr/99937/, 'correct id')->content_unlike(qr/passed/)->content_unlike(qr/incomplete/)
      ->json_like('/id' => qr/^99937$/)->json_hasnt('/result');
    $t->get_ok('/api/v1/obs_rsync/Proj1/test_result?version=469.1&full=1')->status_is(200, 'status')
      ->content_like(qr/99937/, 'correct id')->content_like(qr/passed/)->content_unlike(qr/incomplete/)
      ->json_like('/id' => qr/^99937$/)->json_has('/result')->json_like('/result' => qr/^passed$/);
};

sub lock_test {
    # use BAIL_OUT because only first failure is important
    BAIL_OUT('Cannot lock') unless $helper->lock('Proj1');
    BAIL_OUT('Shouldnt lock') if $helper->lock('Proj1');
    BAIL_OUT('Cannot unlock') unless $helper->unlock('Proj1');
    BAIL_OUT('Cannot lock') unless $helper->lock('Proj1');
    BAIL_OUT('Shouldnt lock') if $helper->lock('Proj1');
    BAIL_OUT('Cannot unlock') unless $helper->unlock('Proj1');
    ok(1, 'lock/unlock behaves as expected');
}

subtest 'test lock smoke' => sub {
    lock_test();
};

subtest 'test lock after failure' => sub {
    # now similate error by deleting the script
    unlink(Mojo::File->new($home, 'script', 'rsync.sh'));
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "trigger rsync");
    perform_minion_jobs($t->app->minion);

    lock_test();
};

done_testing();
