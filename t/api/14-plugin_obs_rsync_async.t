# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use IPC::Run qw(start);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';
use Mojo::IOLoop;
use Time::HiRes 'sleep';

my %config = (concurrency => 2, queue_limit => 4, retry_interval => 1, retry_max_count => 2);
my ($t, $tempdir, $home) = setup_obs_rsync_test(config => \%config);
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

sub start_gru {
    start sub {    # uncoverable because we do not track coverage of this sub process
        note('starting gru');    # uncoverable statement
        $0 = 'openqa-gru';    # uncoverable statement
        $ENV{MOJO_MODE} = 'test';    # uncoverable statement
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'gru', 'run', '-m', 'test');    # uncoverable statement
    };
}

# we need gru running to test response 200
my $gru = start_gru();

sub _jobs {
    my $results = $t->app->minion->backend->list_jobs(0, 400, {tasks => ['obs_rsync_run'], states => \@_});
    return $results->{total}, $results->{jobs};
}

sub _jobs_cnt {
    (my $cnt, undef) = _jobs(@_);
    return $cnt;
}

sub sleep_until_job_start {
    my ($t, $project) = @_;
    my $status = 'active';
    my $retries = 500;

    while ($retries > 0) {
        (undef, my $jobs) = _jobs($status);
        for my $other_job (@$jobs) {
            return 1
              if ( $other_job->{args}
                && ($other_job->{args}[0]->{project} eq $project)
                && $other_job->{notes}{project_lock});
        }
        sleep .2;    # uncoverable statement
        $retries--;    # uncoverable statement
    }
    die 'Timeout reached';    # uncoverable statement
}

sub sleep_until_all_jobs_finished {
    my ($t, $project) = @_;
    my $retries = 500;

    while ($retries > 0) {
        my ($cnt, $jobs) = _jobs('inactive', 'active');
        return 1 unless $cnt;
        sleep .2;    # uncoverable statement
        $retries--;    # uncoverable statement
    }
    die 'Timeout reached';    # uncoverable statement
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
        -f $filename || next;
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
is(_jobs_cnt('finished'), 5, 'Number of finished jobs');

subtest 'test concurrenctly long running jobs again' => sub {
    test_async($t);
};

sleep_until_all_jobs_finished($t);

# the same check will double amount of finished jobs
is(_jobs_cnt('finished'), 10, 'Number of finished jobs');

$t->put_ok('/api/v1/obs_rsync/MockProjectError/runs')->status_is(201, 'Start another mock project');

sleep_until_all_jobs_finished($t);

# MockProjectError should not be raised because errors are ignored
is(_jobs_cnt('finished'), 11, 'Number of finished jobs');
my ($cnt, $jobs) = _jobs('failed');
is($cnt, 0, 'Number of failed jobs');

($cnt, $jobs) = _jobs('finished');
is($jobs->[0]->{result}->{message}, 'Mock Error', 'Correct error message');
is($jobs->[0]->{result}->{code}, 256, 'Correct exit code') if $cnt;

END {
    $gru->signal('TERM');
    $gru->finish;
}

done_testing();
