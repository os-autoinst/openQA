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
# with this program; if not, see <http://www.gnu.org/licenses/>.

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
my $concurrency    = 2;
my $queue_limit    = 2;
my $retry_interval = 1;
$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
queue_limit=$queue_limit
concurrency=$concurrency
retry_interval=$retry_interval
EOF

my $t = Test::Mojo->new('OpenQA::WebAPI');

# Allow Devel::Cover to collect stats for background jobs
$t->app->minion->on(
    worker => sub {
        my ($minion, $worker) = @_;
        $worker->on(
            dequeue => sub {
                my ($worker, $job) = @_;
                $job->on(cleanup => sub { Devel::Cover::report() if Devel::Cover->can('report') });
            });
    });

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

$t->app->minion->perform_jobs;

subtest 'appliances' => sub {
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=images')->status_is(201, "trigger with repository parameter");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=images')
      ->status_is(208, "trigger with repository parameter again");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs?repository=appliances')
      ->status_is(201, "trigger with different repository");
};

$t->app->minion->perform_jobs;

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

    $t->app->minion->perform_jobs;

    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "Proj1 just starts as queue is empty now");
}

subtest 'test queue' => sub {
    test_queue($t);
};
$t->app->minion->perform_jobs;

subtest 'test queue again' => sub {
    test_queue($t);
};

$t->app->minion->perform_jobs;

sub lock_test() {
    my $helper = $t->app->obs_rsync;
    # use BAIL_OUT because only first failure is important
    BAIL_OUT('Cannot lock') unless $helper->lock('Proj1');
    BAIL_OUT('Shouldnt lock') if $helper->lock('Proj1');
    BAIL_OUT('Cannot unlock') unless $helper->unlock('Proj1');
    BAIL_OUT('Cannot lock')   unless $helper->lock('Proj1');
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
    $t->app->minion->perform_jobs;

    lock_test();
};

done_testing();
