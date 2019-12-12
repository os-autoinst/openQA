# Copyright (C) 2015-2019 SUSE LLC
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

package OpenQA::Scheduler::Model::Jobs;
use Mojo::Base 'Mojo::EventEmitter';

use Data::Dump 'pp';
use DateTime;
use File::Temp 'tempdir';
use Try::Tiny;
use OpenQA::Jobs::Constants;
use OpenQA::Utils qw(log_debug log_info log_warning random_string);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKERS_CHECKER_THRESHOLD);
use OpenQA::Schema;
use Time::HiRes 'time';
use List::Util qw(all shuffle);

# How many jobs to allocate in one tick. Defaults to 80 ( set it to 0 for as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 80;

has scheduled_jobs  => sub { {} };
has shuffle_workers => 1;

sub schedule {
    my $self = shift;

    my $start_time  = time;
    my $schema      = OpenQA::Schema->singleton;
    my $all_workers = $schema->resultset("Workers")->count();

    my @f_w = grep { !$_->dead && ($_->websocket_api_version() || 0) == WEBSOCKET_API_VERSION }
      $schema->resultset("Workers")->search({job_id => undef, error => undef})->all();

    my @free_workers = $self->shuffle_workers ? shuffle(@f_w) : @f_w;
    if (@free_workers == 0) {
        $self->emit('conclude');
        return ();
    }

    log_debug("+=" . ("-" x 16) . "=+");
    log_debug("-> Scheduling new jobs.");
    log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");

    $self->_update_scheduled_jobs;
    my $scheduled_jobs = $self->scheduled_jobs;
    log_debug("\t Scheduled jobs: " . scalar(keys %$scheduled_jobs));

    # update the matching workers to the current free
    for my $jobinfo (values %$scheduled_jobs) {
        $jobinfo->{matching_workers} = _matching_workers($jobinfo, \@free_workers);
    }

    my $allocated_jobs    = {};
    my $allocated_workers = {};

    # before we start looking at sorted jobs, we try to repair half
    # scheduled clusters. This can happen e.g. with workers connected to
    # multiple webuis
    $self->_pick_siblings_of_running($allocated_jobs, $allocated_workers);

    my @sorted = sort { $a->{priority} <=> $b->{priority} || $a->{id} <=> $b->{id} } values %$scheduled_jobs;
    my %checked_jobs;
    for my $j (@sorted) {
        next if $checked_jobs{$j->{id}};
        next unless @{$j->{matching_workers}};
        my $tobescheduled = _to_be_scheduled($j, $scheduled_jobs);
        next if defined $allocated_jobs->{$j->{id}};
        next unless $tobescheduled;
        my @tobescheduled = grep { $_->{id} } @$tobescheduled;
        log_debug "need to schedule " . scalar(@tobescheduled) . " jobs for $j->{id}($j->{priority})";
        next unless @tobescheduled;
        my %taken;
        for my $sub_job (sort { $a->{id} <=> $b->{id} } @tobescheduled) {
            $checked_jobs{$sub_job->{id}} = 1;
            my $picked_worker;
            for my $worker (@{$sub_job->{matching_workers}}) {
                next if $allocated_workers->{$worker->id};
                next if $taken{$worker->id};
                $picked_worker = $worker;
                last;
            }
            if (!$picked_worker) {
                # we failed to allocate a worker for all jobs in the
                # cluster, so discard all of them. But as it would be
                # their turn, give the jobs which already got a worker
                # a bonus on their priority
                for my $worker (keys %taken) {
                    my $ji = $taken{$worker};
                    # we only consider the priority of the main job
                    if ($j->{priority} > 0) {
                        # this means we will increase the offset per half-assigned job,
                        # so if we miss 1/25 jobs, we'll bump by +24
                        log_debug "Discarding $ji->{id}($j->{priority}) due to incomplete cluster";
                        $j->{priority_offset} += 1;
                    }
                    else {
                        # don't "take" the worker, but make sure it's not
                        # used for another job and stays around
                        log_debug "Holding worker $worker for $ji->{id} to avoid starvation";
                        $allocated_workers->{$worker} = $ji->{id};
                    }

                }
                %taken = ();
                last;
            }
            $taken{$picked_worker->id} = $sub_job;
        }
        for my $worker (keys %taken) {
            my $ji = $taken{$worker};
            $allocated_workers->{$worker} = $ji->{id};
            $allocated_jobs->{$ji->{id}} = {job => $ji->{id}, worker => $worker};
        }
        # we make sure we schedule clusters no matter what,
        # but we stop if we're over the limit
        my $busy = scalar(keys %$allocated_workers);
        last if $busy >= MAX_JOB_ALLOCATION;
        last if $busy >= scalar(@free_workers);
    }

    my @successfully_allocated;

    # assign the allocated job-worker pairs
    for my $allocated (values %$allocated_jobs) {
        # find worker
        my $worker_id = $allocated->{worker};
        my $worker;
        try {
            $worker = $schema->resultset('Workers')->find({id => $worker_id});
        }
        catch {
            log_debug("Failed to retrieve worker ($worker_id) in the DB, reason: $_");
        };
        next unless $worker;
        if ($worker->unfinished_jobs->count) {
            log_debug "Worker already got jobs, skipping";
            next;
        }

        # take directly chained jobs into account
        # note: That these jobs have a matching WORKER_CLASS is enforced on dependency creation.
        my $first_job_id   = $allocated->{job};
        my $cluster_info   = $scheduled_jobs->{$first_job_id}->{cluster_jobs};
        my $jobs_resultset = $schema->resultset('Jobs');
        my %sort_criteria  = map {
            my $job_id = $_;
            my $sort_criteria;
            if (my $scheduled_job = $scheduled_jobs->{$job_id}) {
                $sort_criteria = $scheduled_job->{test};
            }
            elsif (my $job = $jobs_resultset->find($job_id)) {
                $sort_criteria = $job->TEST;
            }
            ($job_id => ($sort_criteria || $job_id));
        } keys %$cluster_info;
        my $sort_function = sub {
            [sort { $sort_criteria{$a} cmp $sort_criteria{$b} } @{shift()}]
        };
        my ($directly_chained_job_sequence, $job_ids)
          = _serialize_directly_chained_job_sequence($first_job_id, $cluster_info, $sort_function);

        # find jobs
        my @jobs;
        my $job_ids_str = join(', ', @$job_ids);
        try {
            @jobs = $schema->resultset('Jobs')->search({id => {-in => $job_ids}});
        }
        catch {
            log_debug("Failed to retrieve jobs ($job_ids_str) in the DB, reason: $_");
        };
        my $actual_job_count = scalar @jobs;
        if ($actual_job_count != scalar @$job_ids) {
            log_debug("Failed to retrieve jobs ($job_ids_str) in the DB, reason: only got $actual_job_count jobs");
            next;
        }

        # check whether the jobs are still scheduled
        if (my @skipped_jobs = grep { $_->state ne SCHEDULED } @jobs) {
            log_debug('Job ' . $_->id . ' no longer scheduled, skipping') for @skipped_jobs;
            next;
        }

        # check whether the jobs have no worker assigned yet (so jobs already pulled as chained children are not
        # scheduled twice)
        if (my @skipped_jobs = grep { defined $_->assigned_worker_id } @jobs) {
            log_debug('Job ' . $_->id . ' has already a worker assigned, skipping') for @skipped_jobs;
            next;
        }

        my $res;
        try {
            if ($actual_job_count > 1) {
                $res
                  = $self->_assign_multiple_jobs_to_worker(\@jobs, $worker, $directly_chained_job_sequence, $job_ids);
            }
            else {
                $res = $jobs[0]->ws_send($worker);
            }
            die "Failed contacting websocket server over HTTP" unless ref($res) eq "HASH" && exists $res->{state};
        }
        catch {
            log_debug("Failed to send data to websocket, reason: $_");
        };

        if (ref($res) eq "HASH" && $res->{state}->{msg_sent} == 1) {
            log_debug("Sent job(s) '$job_ids_str' to worker '$worker_id'");

            # associate the worker to the job, so the worker can send updates
            try {
                if ($actual_job_count > 1) {
                    my %worker_assignment = (
                        state              => ASSIGNED,
                        t_started          => undef,
                        assigned_worker_id => $worker_id,
                    );
                    $_->update(\%worker_assignment) for @jobs;
                    $worker->update({job_id => $first_job_id});
                    # note: The job_id column of the workers table is updated as soon as the worker progresses
                    #       to the next job so the actually current job and current module can be displayed.
                }
                else {
                    if ($jobs[0]->set_assigned_worker($worker)) {
                        push(@successfully_allocated, {job => $first_job_id, worker => $worker_id});
                    }
                    else {
                        # Send abort and reschedule if we fail associating the job to the worker
                        $jobs[0]->reschedule_rollback($worker);
                    }
                }
            }
            catch {
                log_debug("Failed to set worker in scheduling state, reason: $_");
            };
        }
        else {
            # reset worker and jobs on failure
            log_debug("Failed sending job(s) '$job_ids_str' to worker '$worker_id'");
            try {
                $worker->unprepare_for_work;
            }
            catch {
                log_debug("Failed resetting unprepare worker, reason: $_");
            };
            for my $job (@jobs) {
                try {
                    # Remove the associated worker and be sure to be in scheduled state.
                    $job->reschedule_state;
                }
                catch {
                    # Again: If we see this, we are in a really bad state.
                    my $job_id = $job->id;
                    log_debug("Failed resetting job '$job_id' to scheduled state, reason: $_");
                };
            }
        }
    }

    my $elapsed_rounded = sprintf("%.5f", (time - $start_time));
    log_debug "Scheduler took ${elapsed_rounded}s to perform operations and allocated "
      . scalar(@successfully_allocated) . " jobs";
    log_debug "Allocated: " . pp($_) for @successfully_allocated;
    $self->emit('conclude');

    return (\@successfully_allocated);
}

sub singleton { state $jobs ||= __PACKAGE__->new }

sub _matching_workers {
    my ($jobinfo, $free_workers) = @_;

    my @filtered;
    for my $worker (@$free_workers) {
        my $matched_all = all { $worker->check_class($_) } @{$jobinfo->{worker_classes}};
        push(@filtered, $worker) if $matched_all;
    }
    return \@filtered;
}

sub _pick_siblings_of_running {
    my ($self, $allocated_jobs, $allocated_workers) = @_;

    my $scheduled_jobs = $self->scheduled_jobs;
    my @need;
    # now fetch the remaining job states of cluster jobs
    for my $jobinfo (values %$scheduled_jobs) {
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            next if defined $scheduled_jobs->{$j};
            push(@need, $j);
        }
    }

    my %clusterjobs;
    my $schema = OpenQA::Schema->singleton;
    my $jobs   = $schema->resultset('Jobs')
      ->search({id => {-in => \@need}, state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    while (my $j = $jobs->next) {
        $clusterjobs{$j->id} = $j->state;
    }

    # first pick cluster jobs with running siblings (prio doesn't matter)
    for my $jobinfo (values %$scheduled_jobs) {
        my $has_cluster_running = 0;
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            if (defined $clusterjobs{$j}) {
                $has_cluster_running = 1;
                last;
            }
        }
        if ($has_cluster_running) {
            for my $w (@{$jobinfo->{matching_workers}}) {
                next if $allocated_workers->{$w->id};
                $allocated_workers->{$w->id} = $jobinfo->{id};
                $allocated_jobs->{$jobinfo->{id}} = {job => $jobinfo->{id}, worker => $w->id};
            }
        }
    }
}

sub _to_be_scheduled_recurse {
    my ($j, $scheduled, $taken) = @_;

    return undef unless $j;
    return undef unless $j->{id};
    return undef if $taken->{$j->{id}};
    # if we were called with undef, this is a sign that
    # the cluster is not fully scheduled (e.g. blocked_by), so
    # take that as mark but return
    $taken->{$j->{id}} = $j;

    my $ci = $j->{cluster_jobs}->{$j->{id}};
    return undef unless $ci;
    for my $s (@{$ci->{parallel_children}}) {
        _to_be_scheduled_recurse($scheduled->{$s}, $scheduled, $taken);
    }
    for my $s (@{$ci->{parallel_parents}}) {
        _to_be_scheduled_recurse($scheduled->{$s}, $scheduled, $taken);
    }
}

sub _to_be_scheduled {
    my ($j, $scheduled) = @_;

    my %taken;
    _to_be_scheduled_recurse($j, $scheduled, \%taken);
    return undef if defined $taken{undef};
    return [values %taken];
}

sub _update_scheduled_jobs {
    my $self = shift;

    # Don't kick off jobs if GRU task they depend on is running
    my $schema       = OpenQA::Schema->singleton;
    my $waiting_jobs = $schema->resultset("GruDependencies")->get_column('job_id')->as_query;

    my $jobs = $schema->resultset("Jobs")->search(
        {
            blocked_by_id => undef,
            state         => OpenQA::Jobs::Constants::SCHEDULED,
            id            => {-not_in => $waiting_jobs},
        });

    my $scheduled_jobs = $self->scheduled_jobs;
    my %currently_scheduled;
    my %cluster_infos;
    my @missing_worker_class;
    while (my $job = $jobs->next) {
        # the priority_offset stays in the hash for the next round
        # and is increased whenever a cluster job has to give up its
        # worker because its siblings failed to find a worker on their
        # own. Once the combined priority reaches 0, the worker pick is sticky
        my $info = $scheduled_jobs->{$job->id} || {priority_offset => 0};
        $currently_scheduled{$job->id} = 1;
        # for easier access
        $info->{id}       = $job->id;
        $info->{priority} = $job->priority - $info->{priority_offset};
        $info->{state}    = $job->state;
        $info->{test}     = $job->TEST;
        if (!$info->{worker_classes}) {
            push(@missing_worker_class, $job->id);
            $info->{worker_classes} = [];
        }
        $info->{cluster_jobs} ||= $cluster_infos{$job->id};

        if (!$info->{cluster_jobs}) {
            $info->{cluster_jobs} = $job->cluster_jobs;
            # it's the same cluster for all, so share
            for my $j (keys %{$info->{cluster_jobs}}) {
                $cluster_infos{$j} = $info->{cluster_jobs};
            }
        }
        $scheduled_jobs->{$job->id} = $info;
    }
    # fetch worker classes
    my $settings
      = $schema->resultset("JobSettings")->search({key => 'WORKER_CLASS', job_id => {-in => \@missing_worker_class}});
    while (my $line = $settings->next) {
        push(@{$scheduled_jobs->{$line->job_id}->{worker_classes}}, $line->value);
    }
    # delete stale entries
    for my $id (keys %$scheduled_jobs) {
        delete $scheduled_jobs->{$id} unless $currently_scheduled{$id};
    }
}

# serializes the sequence of directly chained jobs inside the specified $cluster_info starting from $first_job_id
# remarks:
#  * Direct dependency chains might be interrupted by regularily chained dependencies. Jobs not reachable from $first_job_id
#    via directly chained dependencies nodes are not included.
#  * Provides a 'flat' list of involved job IDs as 2nd return value.
#  * See subtest 'serialize sequence of directly chained dependencies' in t/05-scheduler-dependencies.t for examples.
sub _serialize_directly_chained_job_sequence {
    my ($first_job_id, $cluster_info, $sort_function) = @_;

    my %visited = ($first_job_id => 1);
    my $sequence
      = _serialize_directly_chained_job_sub_sequence([$first_job_id], \%visited,
        $cluster_info->{$first_job_id}->{directly_chained_children},
        $cluster_info, $sort_function // sub { return shift });
    return ($sequence, [keys %visited]);
}
sub _serialize_directly_chained_job_sub_sequence {
    my ($output_array, $visited, $child_job_ids, $cluster_info, $sort_function) = @_;

    for my $current_job_id (@{$sort_function->($child_job_ids)}) {
        die "detected cycle at $current_job_id" if $visited->{$current_job_id}++;
        my $sub_sequence
          = _serialize_directly_chained_job_sub_sequence([$current_job_id], $visited,
            $cluster_info->{$current_job_id}->{directly_chained_children},
            $cluster_info, $sort_function);
        push(@$output_array, scalar @$sub_sequence > 1 ? $sub_sequence : $sub_sequence->[0]) if @$sub_sequence;
    }
    return $output_array;
}

sub _assign_multiple_jobs_to_worker {
    my ($self, $jobs, $worker, $directly_chained_job_sequence, $job_ids) = @_;

    # prepare job data for the worker
    my $worker_id = $worker->id;
    my %job_data;
    my %job_info = (
        ids                => $job_ids,
        data               => \%job_data,
        sequence           => $directly_chained_job_sequence,
        assigned_worker_id => $worker_id,
    );
    my $first_job         = $directly_chained_job_sequence->[0];
    my %worker_properties = (
        JOBTOKEN      => random_string(),
        WORKER_TMPDIR => tempdir(),
    );
    for my $job (@$jobs) {
        my $job_id   = $job->id;
        my $job_data = $job->prepare_for_work($worker, \%worker_properties);
        $job_data{$job_id} = $job_data;
    }

    return OpenQA::WebSockets::Client->singleton->send_jobs(\%job_info);
}

sub incomplete_and_duplicate_stale_jobs {
    my ($self) = @_;

    try {
        my $schema = OpenQA::Schema->singleton;
        $schema->txn_do(
            sub {
                my $stale_jobs = $schema->resultset('Jobs')->stale_ones(WORKERS_CHECKER_THRESHOLD);
                for my $job ($stale_jobs->all) {
                    $job->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
                    my $res = $job->auto_duplicate;
                    if ($res) {
                        log_warning(sprintf('Dead job %d aborted and duplicated %d', $job->id, $res->id));
                    }
                    else {
                        log_warning(sprintf('Dead job %d aborted as incomplete', $job->id));
                    }
                }
            });
    }
    catch {
        log_info("Failed stale job detection : $_");
    };
}

1;
