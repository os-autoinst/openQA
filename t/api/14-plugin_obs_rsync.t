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
use Test::MockModule;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);

OpenQA::Test::Case->new->init_data;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home           = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
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

my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

subtest 'smoke' => sub {
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "trigger rsync");
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')->status_is(404, "trigger rsync wrong project");
    $t->put_ok('/admin/obs_rsync/Proj1/runs')->status_is(404, "trigger rsync non-api path");
};

$t->app->start('gru', 'run', '--oneshot');

sub test_queue {
    my $t = shift;
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs')
      ->status_is(201, "Proj2 first time - should just start as queue is empty");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs')
      ->status_is(208, "Proj2 second time - should report IN_QUEUE, because another Proj2 wasn't started by worker");
    $t->put_ok('/api/v1/obs_rsync/Proj3/runs')->status_is(201, "Proj3 first time - should just start");
    $t->put_ok('/api/v1/obs_rsync/Proj2/runs')->status_is(208, "Proj2 still gets queued");
    $t->put_ok('/api/v1/obs_rsync/Proj3/runs')->status_is(208, "Proj3 now reports that already queued");
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')
      ->status_is(507, "Proj1 cannot be handled because queue is full 2=(Proj2, Proj3 running)");
    $t->put_ok('/api/v1/obs_rsync/Proj3/runs')->status_is(208, "Proj3 is still in queue");
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')->status_is(404, "wrong project still returns error");

    $t->app->start('gru', 'run', '--oneshot');

    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "Proj1 just starts as queue is empty now");
}

subtest 'test queue' => sub {
    test_queue($t);
};
$t->app->start('gru', 'run', '--oneshot');

subtest 'test queue again' => sub {
    test_queue($t);
};
$t->app->start('gru', 'run', '--oneshot');

done_testing();
