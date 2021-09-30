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
@EXPORT_OK = (qw(acquire_limit_lock_or_retry finish_job_if_disk_usage_below_percentage));

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


1;
