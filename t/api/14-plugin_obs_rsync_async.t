# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use IPC::Run qw(start);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '16';
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';
use Mojo::IOLoop;
use Time::HiRes 'sleep';

my %config = (concurrency => 2, queue_limit => 4, retry_interval => 1, retry_max_count => 2);
my ($t, $tempdir, $home) = setup_obs_rsync_test(config => \%config);
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

sub start_gru {
    start sub {
        note('starting gru');
        $0 = 'openqa-gru';
        $ENV{MOJO_MODE} = 'test';
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'gru', 'run', '-m', 'test');
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

        sleep .2;
        $retries--;
    }
    die 'Timeout reached';
}

sub sleep_until_all_jobs_finished {
    my ($t, $project) = @_;
    my $retries = 500;

    while ($retries > 0) {
        my ($cnt, $jobs) = _jobs('inactive', 'active');
        return 1 unless $cnt;

        sleep .2;
        $retries--;
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

# MockProjectError will fail so number of finished jobs should remain, but one job must be failed
is(_jobs_cnt('finished'), 10, 'Number of finished jobs');
my ($cnt, $jobs) = _jobs('failed');
is($cnt, 1, 'Number of finished jobs');
is($jobs->[0]->{result}->{message}, 'Mock Error', 'Correct error message') if $cnt;

subtest 'test max retry count' => sub {
    # use all concurrency slots to reach concurrency limit
    my @guards = map { $t->app->obs_rsync->concurrency_guard() } (1 .. $config{queue_limit});
    # put request and make sure it succeeded within 5 sec
    $t->put_ok('/api/v1/obs_rsync/Proj1/runs')->status_is(201, "trigger rsync");

    my $sleep = .2;
    my $empiristic = 3;    # this accounts gru timing in worst case for job run and retry
    my $max_iterations = ($config{retry_max_count} + 1) * ($empiristic + $config{retry_interval}) / $sleep;
    for (1 .. $max_iterations) {
        ($cnt, $jobs) = _jobs('finished');
        last if $cnt > 10;
        sleep $sleep;
    }

    is($cnt, 11, 'Job should retry succeed');
    is($jobs->[0]->{retries}, $config{retry_max_count}, 'Job retris is correct');
    is(ref $jobs->[0]->{result}, 'HASH', 'Job retry result is hash');
    is(
        $jobs->[0]->{result}->{message},
        "Exceeded retry count $config{retry_max_count}. Consider job will be re-triggered later",
        'Job retry message'
    ) if ref $jobs->[0]->{result} eq 'HASH';
    # unlock guards
    @guards = undef;
};

END {
    $gru->signal('TERM');
    $gru->finish;
}

done_testing();
