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
use Time::HiRes 'sleep';
use File::Copy::Recursive 'dircopy';

OpenQA::Test::Case->new->init_data;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";
dircopy($home_template, $home);
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
    die 'Cannot fork gru' unless defined(my $gru_pid = fork());
    if ($gru_pid == 0) {
        Test::More::note('starting gru');
        $ENV{MOJO_MODE} = 'test';
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'gru', 'run', '-m', 'test');
        exit(0);
    }
    return $gru_pid;
}

# we need gru running to test response 200
my $gru_pid = start_gru();

sub sleep_until_job_start {
    my ($t, $project) = @_;
    my $status  = 'active';
    my $retries = 500;

    while ($retries > 0) {
        my $results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => [$status]});
        for my $other_job (@{$results->{jobs}}) {
            return 1
              if ( $other_job->{args}
                && ($other_job->{args}[0]->{project} eq $project)
                && $other_job->{notes}{project_lock});
        }

        sleep(0.2);
        $retries = $retries - 1;
    }
    die 'Timeout reached';
}

sub sleep_until_all_jobs_finished {
    my ($t, $project) = @_;
    my $retries = 500;

    while ($retries > 0) {
        my $results
          = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => ['inactive', 'active']});
        return 1 if !$results->{total};

        sleep(0.2);
        $retries = $retries - 1;
    }
    die 'Timeout reached';
}

# this function communicates with t/data/openqa-trigger-from-obs/script/rsync.sh
# when file .$project-ready is created, then rsync process should finish
sub signal_rsync_ready {
    foreach (@_) {
        my $filename = Mojo::File->new($home, 'script', ".$_-ready")->to_string;
        open my $fh, '>', $filename || die "Cannot create file $filename: $!";
        close $fh;
    }
}

sub unlink_signal_rsync_ready {
    foreach (@_) {
        my $filename = Mojo::File->new($home, 'script', ".$_-ready")->to_string;
        -f $filename     || next;
        unlink $filename || die "Cannot unlink file $filename: $!";
    }
}

sub test_async {
    my $t = shift;
    unlink_signal_rsync_ready('MockProjectLongProcessing', 'MockProjectLongProcessing1');

    # MockProjectLongProcessing causes job to sleep some sec, so we can reach job limit
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(201, 'first request to MockProjectLongProcessing should start');

    sleep_until_job_start($t, 'MockProjectLongProcessing');

    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(200, 'second request to MockProjectLongProcessing should be queued');
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(208, 'third request to MockProjectLongProcessing should report already in queue');
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(201, 'first request to MockProjectLongProcessing1 should start');
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing/runs')
      ->status_is(208, 'request for MockProjectLongProcessing still reports in queue');

    sleep_until_job_start($t, 'MockProjectLongProcessing1');

    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(200, 'second request to MockProjectLongProcessing1 is queued');
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(208, 'now MockProjectLongProcessing1 should report already in queue');
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(507, 'Queue limit is reached 4=(2 running + 2 scheduled)');
    $t->put_ok('/api/v1/obs_rsync/MockProjectLongProcessing1/runs')
      ->status_is(208, 'MockProjectLongProcessing1 still in queue');
    $t->put_ok('/api/v1/obs_rsync/WRONGPROJECT/runs')
      ->status_is(404, 'trigger rsync wrong project still returns error');

    signal_rsync_ready('MockProjectLongProcessing', 'MockProjectLongProcessing1');
    sleep_until_all_jobs_finished($t);

    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, 'Proj1 just starts as gru should empty queue for now');
}

subtest 'test concurrenctly long running jobs' => sub {
    test_async($t);
};

sleep_until_all_jobs_finished($t);

# now we should have 5 finished jobs: 2 for MockProjectLongProcessing and MockProjectLongProcessing1 and one for Proj1
my $results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => ['finished']});
ok(5 == $results->{total}, 'Number of finished jobs ' . $results->{total});

subtest 'test concurrenctly long running jobs again' => sub {
    test_async($t);
};

sleep_until_all_jobs_finished($t);

# the same check will double amount of finished jobs
$results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => ['finished']});
ok(10 == $results->{total}, 'Number of finished jobs ' . $results->{total});

$t->put_ok('/api/v1/obs_rsync/MockProjectError/runs')->status_is(201, 'Start another mock project');

sleep_until_all_jobs_finished($t);

# MockProjectError will fail so number of finished jobs should remain, but one job must be failed
$results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => ['finished']});
ok(10 == $results->{total}, 'Number of finished jobs ' . $results->{total});
$results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => ['failed']});
ok(1 == $results->{total}, 'Number of failed jobs ' . $results->{total});

ok(1 == $results->{total} && $results->{jobs}[0]->{result}->{message} eq 'Mock Error', 'Correct error message');

if ($gru_pid) {
    kill('TERM', $gru_pid);
    waitpid($gru_pid, 0);
}

done_testing();
