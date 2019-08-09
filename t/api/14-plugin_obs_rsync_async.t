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
use Test::MockModule;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);

OpenQA::Test::Case->new->init_data;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home           = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $concurrency    = 2;
my $queue_limit    = 4;
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

sub start_gru {
    my $gru_pid = fork();
    if ($gru_pid == 0) {
        print("starting gru\n");
        $ENV{MOJO_MODE} = 'test';
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'gru', 'run', '-m', 'test');
        exit(0);
    }
    return $gru_pid;
}

# we need gru running to test response 200
my $gru_pid = start_gru();

ok($gru_pid);

# let gru start
sleep 1;

sub test_async {
    my $t = shift;
    # MockProjectLongProcessing causes job to sleep some sec, so we can reach job limit
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(201, "first request to MockProjectLongProcessing should start");
    sleep 2;
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(200, "second request to MockProjectLongProcessing should be queued");
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(208, "third request to MockProjectLongProcessing should report already in queue");
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(201, "first request to MockProjectLongProcessing1 should start");
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(208, "request for MockProjectLongProcessing still reports in queue");
    sleep 1;
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(200, "second request to MockProjectLongProcessing1 is queued");
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(208, "now MockProjectLongProcessing1 should report already in queue");
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(507, "Queue limit is reached 4=(2 running + 2 scheduled)");
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(208, "MockProjectLongProcessing1 still in queue");
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')
      ->status_is(404, "trigger rsync wrong project still returns error");
    sleep 4;
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "Proj1 just starts as gru should empty queue for now");
}

subtest 'test concurrenctly long running jobs' => sub {
    test_async($t);
};

sleep 5;

subtest 'test concurrenctly long running jobs again' => sub {
    test_async($t);
};

if ($gru_pid) {
    kill('TERM', $gru_pid);
    waitpid($gru_pid, 0);
}

done_testing();
