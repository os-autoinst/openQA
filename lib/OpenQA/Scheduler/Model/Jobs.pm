# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::Model::Jobs;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Data::Dump 'pp';
use DateTime;
use File::Temp 'tempdir';
use Try::Tiny;
use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_debug log_info log_warning);
use OpenQA::Utils 'random_string';
use OpenQA::Constants qw(WEBSOCKET_API_VERSION);
use OpenQA::Schema;
use OpenQA::Scheduler::WorkerSlotPicker;
use Time::HiRes 'time';
use List::Util qw(all any shuffle min sum);

# How many jobs to allocate in one tick. Defaults to 80 ( set it to 0 for as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 80;
use constant MAX_REPORT_MISSING_WORKER_CLASSES => $ENV{OPENQA_SCHEDULER_MAX_REPORT_MISSING_WORKER_CLASSES} // 30;

# How much the priority should be increased (the priority value decreased) to protect a parallel cluster from starvation
use constant STARVATION_PROTECTION_PRIORITY_OFFSET => $ENV{OPENQA_SCHEDULER_STARVATION_PROTECTION_PRIORITY_OFFSET} // 1;

has scheduled_jobs => sub { {} };
has shuffle_workers => 1;

sub determine_free_workers ($shuffle = 0) {
    my @free_workers = grep { !$_->dead && ($_->websocket_api_version() || 0) == WEBSOCKET_API_VERSION }
      OpenQA::Schema->singleton->resultset('Workers')->search({job_id => undef, error => undef})->all;
    return $shuffle ? shuffle(\@free_workers) : \@free_workers;
}

sub determine_scheduled_jobs ($self) {
    $self->_update_scheduled_jobs;
    return $self->scheduled_jobs;
}

sub _allocate_worker_slot ($self, $allocated_workers, $worker, $job_info) {
    $allocated_workers->{$worker->id} = $job_info->{id};

    # set "one_host_only_via_worker"-flag for whole cluster if the allocated worker slot has
    # the PARALLEL_ONE_HOST_ONLY property
    # note: This is done so that _pick_siblings_of_running() can take it into account. To be able to reset this flag
    #       on the next tick a separate flag is used here (and not just "one_host_only").
    return undef unless $worker->get_property('PARALLEL_ONE_HOST_ONLY');
    my $scheduled_jobs = $self->scheduled_jobs;
    my $cluster_jobs = $job_info->{cluster_jobs};
    $job_info->{one_host_only_via_worker} = 1;
    for my $job_id (keys %$cluster_jobs) {
        next unless my $cluster_job = $scheduled_jobs->{$job_id};
        $cluster_job->{one_host_only_via_worker} = 1;
    }
}

sub _allocate_jobs ($self, $free_workers) {
    my ($allocated_workers, $allocated_jobs) = ({}, {});
    my $scheduled_jobs = $self->scheduled_jobs;
    my $schema = OpenQA::Schema->singleton;
    my $running = $schema->resultset('Jobs')->count({state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    my $limit = OpenQA::App->singleton->config->{scheduler}->{max_running_jobs};
    if ($limit >= 0 && $running >= $limit) {
        log_debug("max_running_jobs ($limit) exceeded, scheduling no additional jobs");
        $self->emit('conclude');
        return ({}, {});
    }
    my $max_allocate = $limit >= 0 ? min(MAX_JOB_ALLOCATION, $limit - $running) : MAX_JOB_ALLOCATION;

    # update the matching workers to the current free
    my %rejected;
    for my $id (keys %$scheduled_jobs) {
        my $jobinfo = $scheduled_jobs->{$id};
        $jobinfo->{matching_workers} = _matching_workers($jobinfo, $free_workers, \%rejected);
        delete $scheduled_jobs->{$id} unless @{$jobinfo->{matching_workers}};
    }
    if (keys %rejected) {
        my @rejected = sort { $rejected{$b} <=> $rejected{$a} || $a cmp $b } keys %rejected;
        splice @rejected, MAX_REPORT_MISSING_WORKER_CLASSES;
        my $stats = join ',', map { "$_:$rejected{$_}" } @rejected;
        my $info = sprintf 'Skipping %d jobs because of no free workers for requested worker classes (%s)',
          sum(values %rejected), $stats;
        log_debug($info);
    }

    # before we start looking at sorted jobs, we try to repair half scheduled clusters
    # note: This can happen e.g. with workers connected to multiple web UIs or when jobs are scheduled
    #       non-atomically via openqa-clone-job.
    $self->_pick_siblings_of_running($allocated_jobs, $allocated_workers);

    my @sorted = sort { $a->{priority} <=> $b->{priority} || $a->{id} <=> $b->{id} } values %$scheduled_jobs;
    my %checked_jobs;
    for my $j (@sorted) {
        next if $checked_jobs{$j->{id}};
        next unless @{$j->{matching_workers}};
        my $tobescheduled = _to_be_scheduled($j, $scheduled_jobs);
        next if defined $allocated_jobs->{$j->{id}};
        next unless $tobescheduled;
        OpenQA::Scheduler::WorkerSlotPicker->new($tobescheduled)->pick_slots_with_common_worker_host;
        my @tobescheduled = grep { $_->{id} } @$tobescheduled;
        my $parallel_count = scalar(@tobescheduled);
        log_debug "Need to schedule $parallel_count parallel jobs for job $j->{id} (with priority $j->{priority})";
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
                my $prio = $j->{priority};    # we only consider the priority of the main job
                for my $worker (keys %taken) {
                    my ($picked_worker, $job_info) = @{$taken{$worker}};
                    $self->_allocate_worker_with_priority($prio, $job_info, $j, $allocated_workers, $picked_worker);
                }
                %taken = ();
                last;
            }
            $taken{$picked_worker->id} = [$picked_worker, $sub_job];
        }
        for my $picked_worker_id (keys %taken) {
            my ($picked_worker, $job_info) = @{$taken{$picked_worker_id}};
            $self->_allocate_worker_slot($allocated_workers, $picked_worker, $job_info);
            $allocated_jobs->{$job_info->{id}}
              = {job => $job_info->{id}, worker => $picked_worker_id, priority_offset => \$j->{priority_offset}};
        }
        # we make sure we schedule clusters no matter what,
        # but we stop if we're over the limit
        my $busy = keys %$allocated_workers;
        if ($busy >= $max_allocate || $busy >= @$free_workers) {
            my $free_worker_count = @$free_workers;
            log_debug('limit reached, scheduling no additional jobs'
                  . " (max_running_jobs=$limit, free workers=$free_worker_count, running=$running, allocated=$busy)");
            last;
        }
    }
    return ($allocated_workers, $allocated_jobs);
}

sub _allocate_worker_with_priority ($self, $prio, $job_info, $j, $allocated_workers, $worker) {
    if ($prio > 0) {
        # this means we will by default increase the offset per half-assigned job,
        # so if we miss 1/25 jobs, we'll bump by +24
        log_debug "Discarding job $job_info->{id} (with priority $prio) due to incomplete parallel cluster"
          . ', reducing priority by '
          . STARVATION_PROTECTION_PRIORITY_OFFSET;
        $j->{priority_offset} += STARVATION_PROTECTION_PRIORITY_OFFSET;
    }
    else {
        # don't "take" the worker, but make sure it's not
        # used for another job and stays around
        my $worker_id = $worker->id;
        log_debug "Holding worker $worker_id for job $job_info->{id} to avoid starvation";
        $self->_allocate_worker_slot($allocated_workers, $worker, $job_info);
    }
}

sub schedule ($self) {
    my $start_time = time;
    my $schema = OpenQA::Schema->singleton;
    my $free_workers = determine_free_workers($self->shuffle_workers);
    my $worker_count = $schema->resultset('Workers')->count;
    my $free_worker_count = @$free_workers;
    unless ($free_worker_count) {
        $self->emit('conclude');
        return [];
    }

    my $scheduled_jobs = $self->determine_scheduled_jobs;
    log_debug(
        "Scheduling: Free workers: $free_worker_count/$worker_count; Scheduled jobs: " . scalar(keys %$scheduled_jobs));

    my ($allocated_workers, $allocated_jobs) = $self->_allocate_jobs($free_workers);
    return [] unless keys %$allocated_workers;

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
            log_debug("Failed to retrieve worker ($worker_id) in the DB, reason: $_");    # uncoverable statement
        };
        next unless $worker;
        if ($worker->unfinished_jobs->count) {
            log_debug 'Worker already got jobs, skipping';
            next;
        }

        # take directly chained jobs into account
        # note: That these jobs have a matching WORKER_CLASS is enforced on dependency creation.
        my $first_job_id = $allocated->{job};
        my $cluster_info = $scheduled_jobs->{$first_job_id}->{cluster_jobs};
        my $jobs_resultset = $schema->resultset('Jobs');
        my %sort_criteria = map {
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
        my ($directly_chained_job_sequence, $job_ids) = try {
            _serialize_directly_chained_job_sequence($first_job_id, $cluster_info, $sort_function);
        }
        catch {
            my $error = $_;
            chomp $error;
            log_info("Unable to serialize directly chained job sequence of $first_job_id: $error");
            # deprioritize jobs with broken directly chained dependencies so they don't prevent other jobs from
            # being assigned
            ${$allocated->{priority_offset}} -= 1;
        };
        next unless $job_ids;

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

        # assign the jobs to the worker and then send the jobs to the worker
        # note: The $worker->update(...) is also done when the worker sends a status update. That is
        #       required to track the worker's current job when assigning multiple jobs to it. We still
        #       need to set it here immediately to be sure the scheduler does not consider the worker
        #       free anymore.
        my $res;
        try {
            if ($actual_job_count > 1) {
                my %worker_assignment = (
                    state => ASSIGNED,
                    t_started => undef,
                    assigned_worker_id => $worker_id,
                );
                $schema->txn_do(
                    sub {
                        $_->update(\%worker_assignment) for @jobs;
                        $worker->set_current_job($jobs[0]);
                    });
                $res
                  = $self->_assign_multiple_jobs_to_worker(\@jobs, $worker, $directly_chained_job_sequence, $job_ids);
            }
            else {
                $schema->txn_do(
                    sub {
                        $jobs[0]->set_assigned_worker($worker);
                        $worker->set_current_job($jobs[0]);
                    });
                $res = $jobs[0]->ws_send($worker);
            }
            die 'Failed contacting websocket server over HTTP' unless ref($res) eq 'HASH' && exists $res->{state};
        }
        catch {
            log_warning "Failed to send data to websocket server, reason: $_";
        };

        my $state = (ref $res eq 'HASH' && ref $res->{state} eq 'HASH') ? $res->{state} : {};
        if ($state->{msg_sent}) {
            # note: That only means the websocket server could *start* sending the message but not that the message
            #       has been received and acknowledged by the worker.
            log_debug("Sent job(s) '$job_ids_str' to worker '$worker_id'");
            push(@successfully_allocated, map { {job => $_, worker => $worker_id} } @$job_ids);
            next;
        }

        # reset worker and jobs on failure
        my $error = $state->{error} // 'unknown error';
        log_warning "Failed sending job(s) '$job_ids_str' to worker '$worker_id': $error";
        try {
            $schema->txn_do(sub { $worker->unprepare_for_work; });
        }
        catch {
            log_warning "Failed resetting unprepare worker, reason: $_";    # uncoverable statement
        };
        for my $job (@jobs) {
            try {
                # remove the associated worker and be sure to be in scheduled state.
                $schema->txn_do(sub { $job->reschedule_state; });
            }
            catch {
                # if we see this, we are in a really bad state
                my $job_id = $job->id;    # uncoverable statement
                log_warning "Failed resetting job '$job_id' to scheduled state, reason: $_";    # uncoverable statement
            };
        }
    }

    my $elapsed_rounded = sprintf('%.5f', (time - $start_time));
    log_debug "Scheduler took ${elapsed_rounded}s to perform operations and allocated "
      . scalar(@successfully_allocated) . ' jobs';
    log_debug 'Allocated: ' . pp($_) for @successfully_allocated;
    $self->emit('conclude');

    return (\@successfully_allocated);
}

sub singleton { state $jobs ||= __PACKAGE__->new }

sub _matching_workers ($jobinfo, $free_workers, $rejected = {}) {
    my @filtered;
    my @needed = sort @{$jobinfo->{worker_classes}};
    for my $worker (@$free_workers) {
        my $matched_all = all { $worker->check_class($_) } @needed;
        push(@filtered, $worker) if $matched_all;
    }
    $rejected->{join ',', @needed}++ unless @filtered;
    return \@filtered;
}

sub _jobs_in_execution ($need) {
    my $jobs_rs = OpenQA::Schema->singleton->resultset('Jobs');
    $jobs_rs->search({id => {-in => $need}, state => [OpenQA::Jobs::Constants::EXECUTION_STATES]})->all;
}

sub _worker_host_of_job ($job) {
    return '' unless my $assigned_worker = $job->assigned_worker;
    return $assigned_worker->host;
}

sub _pick_siblings_of_running ($self, $allocated_jobs, $allocated_workers) {
    my $scheduled_jobs = $self->scheduled_jobs;
    my @need;
    # determine the IDs of unallocated jobs in parallel clusters of currently scheduled jobs
    for my $jobinfo (values %$scheduled_jobs) {
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            push @need, $j unless defined $scheduled_jobs->{$j};
        }
    }

    # determine all running jobs in parallel clusters of currently scheduled jobs and their worker host
    my %clusterjobs = map { ($_->id => _worker_host_of_job $_) } _jobs_in_execution(\@need);

    # pick jobs with running parallel siblings (prio doesn't matter)
    for my $jobinfo (values %$scheduled_jobs) {
        my $worker_host;
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            last if $worker_host = $clusterjobs{$j};
        }
        last unless $worker_host;
        for my $w (@{$jobinfo->{matching_workers}}) {
            next if $allocated_workers->{$w->id};
            $self->_allocate_worker_slot($allocated_workers, $w, $jobinfo);
            next if ($jobinfo->{one_host_only} || $jobinfo->{one_host_only_via_worker}) && ($w->host ne $worker_host);
            $allocated_jobs->{$jobinfo->{id}} = {job => $jobinfo->{id}, worker => $w->id};
        }
    }
}

sub _to_be_scheduled_recurse ($j, $scheduled, $taken) {
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

sub _to_be_scheduled ($j, $scheduled) {
    my %taken;
    _to_be_scheduled_recurse($j, $scheduled, \%taken);
    return undef if defined $taken{undef};
    return [values %taken];
}

sub _update_scheduled_jobs ($self) {
    my $cur_time = DateTime->now(time_zone => 'UTC');
    my $max_job_scheduled_time = OpenQA::App->singleton->config->{scheduler}->{max_job_scheduled_time};

    # consider all scheduled jobs not being blocked by a parent job or Gru task
    my $schema = OpenQA::Schema->singleton;
    my $waiting_jobs = $schema->resultset('GruDependencies')->get_column('job_id')->as_query;
    my $jobs = $schema->resultset('Jobs')
      ->search({id => {-not_in => $waiting_jobs}, blocked_by_id => undef, state => SCHEDULED});

    my $scheduled_jobs = $self->scheduled_jobs;
    my %currently_scheduled;
    my %cluster_infos;
    my @missing_worker_class;
    while (my $job = $jobs->next) {
        # cancel jobs exceeding the max. time a job may be scheduled
        if (($cur_time - $job->t_created)->delta_days > $max_job_scheduled_time) {
            $job->cancel(OpenQA::Jobs::Constants::OBSOLETED, "scheduled for more than $max_job_scheduled_time days");
            next;
        }

        # the priority_offset stays in the hash for the next round
        # and is increased whenever a cluster job has to give up its
        # worker because its siblings failed to find a worker on their
        # own. Once the combined priority reaches 0, the worker pick is sticky
        my $info = $scheduled_jobs->{$job->id} || {priority_offset => 0};
        $currently_scheduled{$job->id} = 1;
        # for easier access
        $info->{id} = $job->id;
        $info->{priority} = $job->priority - $info->{priority_offset};
        $info->{state} = $job->state;
        $info->{test} = $job->TEST;
        if (!$info->{worker_classes}) {
            push(@missing_worker_class, $job->id);
            $info->{worker_classes} = [];
        }

        my $cluster_jobs = $info->{cluster_jobs} ||= $cluster_infos{$job->id};
        if (!$cluster_jobs) {
            $cluster_jobs = $info->{cluster_jobs} = $job->cluster_jobs;
            # it's the same cluster for all, so share
            $cluster_infos{$_} = $cluster_jobs for keys %$cluster_jobs;
        }
        $info->{one_host_only_via_worker} = 0;
        $info->{one_host_only} = any { $_->{one_host_only} } values %$cluster_jobs;
        $scheduled_jobs->{$job->id} = $info;
    }
    # fetch worker classes
    my $settings
      = $schema->resultset('JobSettings')->search({key => 'WORKER_CLASS', job_id => {-in => \@missing_worker_class}});
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
#  * Direct dependency chains might be interrupted by regularly chained dependencies. Jobs not reachable from $first_job_id
#    via directly chained dependencies nodes are not included.
#  * Stops following a direct (sub)chain when a job has been encountered which is not SCHEDULED anymore.
#  * Provides a 'flat' list of involved job IDs as 2nd return value.
#  * See subtest 'serialize sequence of directly chained dependencies' in
#    t/05-scheduler-serialize-directly-chained-dependencies.t for examples.
sub _serialize_directly_chained_job_sequence ($first_job_id, $cluster_info, $sort_function = undef) {
    my %visited = ($first_job_id => 1);
    my $sequence
      = _serialize_directly_chained_job_sub_sequence([$first_job_id], \%visited,
        $cluster_info->{$first_job_id}->{directly_chained_children},
        $cluster_info, $sort_function // sub { return shift });
    return ($sequence, [keys %visited]);
}
sub _serialize_directly_chained_job_sub_sequence ($output_array, $visited, $child_job_ids, $cluster_info,
    $sort_function)
{
    for my $current_job_id (@{$sort_function->($child_job_ids)}) {
        my $current_job_info = $cluster_info->{$current_job_id};
        next unless $current_job_info->{state} eq SCHEDULED;
        die "detected cycle at $current_job_id\n" if $visited->{$current_job_id}++;
        my $sub_sequence
          = _serialize_directly_chained_job_sub_sequence([$current_job_id], $visited,
            $current_job_info->{directly_chained_children},
            $cluster_info, $sort_function);
        push(@$output_array, scalar @$sub_sequence > 1 ? $sub_sequence : $sub_sequence->[0]) if @$sub_sequence;
    }
    return $output_array;
}

sub _assign_multiple_jobs_to_worker ($self, $jobs, $worker, $directly_chained_job_sequence, $job_ids) {
    # prepare job data for the worker
    my $worker_id = $worker->id;
    my %job_data;
    my %job_info = (
        ids => $job_ids,
        data => \%job_data,
        sequence => $directly_chained_job_sequence,
        assigned_worker_id => $worker_id,
    );
    my $first_job = $directly_chained_job_sequence->[0];
    if (my $tmpdir = $worker->get_property('WORKER_TMPDIR')) {
        File::Path::rmtree($tmpdir);
    }
    my %worker_properties = (
        JOBTOKEN => random_string(),
        WORKER_TMPDIR => tempdir(sprintf('scheduler.worker-%d.XXXXXXXX', $worker_id), TMPDIR => 1));
    $worker->set_property(WORKER_TMPDIR => $worker_properties{WORKER_TMPDIR});
    $job_data{$_->id} = $_->prepare_for_work($worker, \%worker_properties) for @$jobs;
    return OpenQA::WebSockets::Client->singleton->send_jobs(\%job_info);
}

sub incomplete_and_duplicate_stale_jobs ($self) {
    try {
        my $schema = OpenQA::Schema->singleton;
        for my $job ($schema->resultset('Jobs')->stale_ones) {
            $schema->txn_do(
                sub {
                    # skip if the worker meanwhile showed up
                    my $worker = $job->assigned_worker // $job->worker;
                    return if $worker && !$worker->dead;

                    # set jobs not touched by the worker so far back to scheduled
                    return if $job->state eq ASSIGNED && $job->reschedule_state;

                    # consider other jobs incomplete
                    my $worker_info = defined $worker ? ('worker ' . $worker->name) : 'worker';
                    $job->done(
                        result => OpenQA::Jobs::Constants::INCOMPLETE,
                        reason => "abandoned: associated $worker_info has not sent any status updates for too long",
                    );
                    my $res = $job->auto_duplicate;
                    if (ref $res) {
                        log_warning(sprintf('Dead job %d aborted and duplicated %d', $job->id, $res->id));
                    }
                    else {
                        log_warning(sprintf('Dead job %d aborted as incomplete', $job->id));
                    }
                });
        }
    }
    catch {
        log_info("Failed stale job detection: $_");
    };
}

1;
