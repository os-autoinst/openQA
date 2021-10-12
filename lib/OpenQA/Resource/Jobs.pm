# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Resource::Jobs;

use strict;
use warnings;

use OpenQA::Jobs::Constants;
use OpenQA::Schema;
use Exporter 'import';

our @EXPORT_OK = qw(job_restart);

=head2 job_restart

=over

=item Arguments: SCALAR or ARRAYREF of Job IDs

=item Return value: ARRAY of new job ids

=back

Handle job restart by user (using API or WebUI). Job is only restarted when either running
or done. Scheduled jobs can't be restarted.

=cut
sub job_restart {
    my ($jobids, %args) = @_;
    my (@duplicates, @processed, @errors, @warnings);
    my %res = (duplicates => \@duplicates, errors => \@errors, warnings => \@warnings, enforceable => 0);
    unless (ref $jobids eq 'ARRAY' && @$jobids) {
        push @errors, 'No job IDs specified';
        return \%res;
    }

    # duplicate all jobs that are either running or done
    my $force = $args{force};
    my %duplication_args = map { ($_ => $args{$_}) } qw(prio skip_parents skip_children skip_ok_result_children);
    my $schema = OpenQA::Schema->singleton;
    my $jobs = $schema->resultset('Jobs')->search({id => $jobids, state => {'not in' => [PRISTINE_STATES]}});
    $duplication_args{no_directly_chained_parent} = 1 unless $force;
    while (my $job = $jobs->next) {
        my $job_id = $job->id;
        my $missing_assets = $job->missing_assets;
        if (@$missing_assets) {
            my $message = "Job $job_id misses the following mandatory assets: " . join(', ', @$missing_assets);
            if (defined $job->parents->first) {
                $message
                  .= "\nYou may try to retrigger the parent job that should create the assets and will implicitly retrigger this job as well.";
            }
            else {
                $message .= "\nEnsure to provide mandatory assets and/or force retriggering if necessary.";
            }
            if ($force) {
                push @warnings, $message;
            }
            else {
                push @errors, $message;
                $res{enforceable} = 1;
                next;
            }
        }
        my $cloned_job_or_error = $job->auto_duplicate(\%duplication_args);
        if (ref $cloned_job_or_error) {
            push @duplicates, $cloned_job_or_error->{cluster_cloned};
        }
        else {
            $res{enforceable} = 1 if index($cloned_job_or_error, 'Direct parent ') == 0;
            push @errors, ($cloned_job_or_error // "An internal error occurred when duplicating $job_id");
        }
        push @processed, $job_id;
    }

    # abort running jobs
    return \%res if $args{skip_aborting_jobs};
    my $running_jobs = $schema->resultset("Jobs")->search(
        {
            id => \@processed,
            state => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        });
    $running_jobs->search({result => OpenQA::Jobs::Constants::NONE})
      ->update({result => OpenQA::Jobs::Constants::USER_RESTARTED});
    while (my $j = $running_jobs->next) {
        $j->calculate_blocked_by;
        $j->abort;
    }
    return \%res;
}

1;
