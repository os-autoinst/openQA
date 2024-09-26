# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Resource::Jobs;

use Mojo::Base -strict, -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Schema;
use OpenQA::Utils qw(create_git_clone_list);
use Exporter 'import';

our @EXPORT_OK = qw(job_restart);

my @DUPLICATION_ARG_KEYS
  = (qw(clone prio skip_parents skip_children skip_ok_result_children settings comment comment_user_id));

=head2 job_restart

=over

=item Arguments: SCALAR or ARRAYREF of Job IDs

=item Return value: ARRAY of new job ids

=back

Handle job restart by user (using API or WebUI). Job is only restarted when either running
or done. Scheduled jobs can't be restarted.

=cut
sub job_restart ($jobids, %args) {
    my (@duplicates, @comments, @processed, @errors, @warnings);
    my %res = (
        duplicates => \@duplicates,
        comments => \@comments,
        errors => \@errors,
        warnings => \@warnings,
        enforceable => 0
    );
    unless (ref $jobids eq 'ARRAY' && @$jobids) {
        push @errors, 'No job IDs specified';
        return \%res;
    }

    # duplicate all jobs that are either running or done
    my $force = $args{force};
    my %duplication_args = map { ($_ => $args{$_}) } @DUPLICATION_ARG_KEYS;
    my $schema = OpenQA::Schema->singleton;
    my $jobs_rs = $schema->resultset('Jobs');
    my $jobs = $jobs_rs->search({id => $jobids, state => {'not in' => [PRISTINE_STATES]}});
    $duplication_args{no_directly_chained_parent} = 1 unless $force;
    my %clones;
    my @clone_ids;
    while (my $job = $jobs->next) {
        my $job_id = $job->id;
        my $missing_assets = $job->missing_assets;
        if (@$missing_assets) {
            my $message = "Job $job_id misses the following mandatory assets: " . join(', ', @$missing_assets);
            if ($job->count_related('parents')) {
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
            create_git_clone_list($job->settings_hash, \%clones);
            push @duplicates, $cloned_job_or_error->{cluster_cloned};
            push @comments, @{$cloned_job_or_error->{comments_created}};
            push @clone_ids, $cloned_job_or_error->{cluster_cloned}->{$job_id};
        }
        else {
            $res{enforceable} = 1 if index($cloned_job_or_error, 'Direct parent ') == 0;
            push @errors, ($cloned_job_or_error // "An internal error occurred when duplicating $job_id");
        }
        push @processed, $job_id;
    }
    OpenQA::App->singleton->gru->enqueue_git_clones(\%clones, \@clone_ids) if keys %clones;

    # abort running jobs
    return \%res if $args{skip_aborting_jobs};
    my $running_jobs = $jobs_rs->search({id => \@processed, state => [EXECUTION_STATES]});
    $running_jobs->search({result => NONE})->update({result => USER_RESTARTED});
    while (my $j = $running_jobs->next) {
        $j->calculate_blocked_by;
        $j->abort;
    }
    return \%res;
}

1;
