# Copyright 2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Utils;
use Mojo::Base -signatures;

use Exporter qw(import);
use OpenQA::Log qw(log_warning);
use OpenQA::Utils qw(check_df);
use Scalar::Util qw(looks_like_number);
use Time::Seconds;

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (
    qw(acquire_limit_lock_or_retry finish_job_if_disk_usage_below_percentage),
    qw(enable_retry_on_signals conclude_on_signals)
);

# acquire lock to prevent multiple limit_* tasks to run in parallel unless
# concurrency is configured to be allowed
sub acquire_limit_lock_or_retry ($job) {
    my $app = $job->app;
    return 1 if $app->config->{cleanup}->{concurrent};
    my $guard = $app->minion->guard('limit_tasks', ONE_DAY);
    return $guard if $guard;
    $job->retry({delay => ONE_MINUTE});
    return 0;
}

sub finish_job_if_disk_usage_below_percentage (%args) {
    my $job = $args{job};
    my $percentage = $job->app->config->{misc_limits}->{$args{setting}};

    unless (looks_like_number($percentage) && $percentage >= 0 && $percentage <= 100) {
        log_warning "Specified value for $args{setting} is not a percentage and will be ignored.";
        return undef;
    }
    return undef if $percentage == 100;

    my $dir = $args{dir};
    my ($available_bytes, $total_bytes) = eval { check_df($dir) };
    if (my $error = $@) {
        log_warning "$error Proceeding with cleanup.";
        return undef;
    }

    my $free_percentage = $available_bytes / $total_bytes * 100;
    return undef if $free_percentage <= $percentage;
    $job->finish("Skipping, free disk space on '$dir' exceeds configured percentage $percentage %"
          . " (free percentage: $free_percentage %)");
    return 1;
}

# define a signal handler for retrying the job after receiving a signal
my $CONCLUDE_ON_SIGNALS = 0;
sub _handle_signal ($job, $signal) {
    # do nothing if the job is supposed to be concluded despite receiving a signal at this point
    return $job->note(signal_handler => "Received signal $signal, concluding") if $CONCLUDE_ON_SIGNALS;

    # schedule a retry before stopping the job's execution prematurely
    $job->note(signal_handler => "Received signal $signal, scheduling retry and releasing locks");
    $job->retry;
    exit;
}

# enables retrying the specified Minion job when receiving SIGTERM/SIGINT
# note: Prevents the job to fail with "Job terminated unexpectedly".
sub enable_retry_on_signals ($job) {
    $SIG{TERM} = $SIG{INT} = sub ($signal) { _handle_signal($job, $signal) };
}

# keeps the job running despite receiving signals
# note: Supposed to be called right before the job would terminate anyways, e.g. before
#       spawning follow-up jobs. This is useful to prevent spawning an incomplete set of
#       follow-up jobs.
sub conclude_on_signals () { $CONCLUDE_ON_SIGNALS = 1 }

1;
