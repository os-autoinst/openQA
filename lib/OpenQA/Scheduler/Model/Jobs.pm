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
use Try::Tiny;
use OpenQA::Jobs::Constants;
use OpenQA::Utils 'log_debug';
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
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

    # NOTE: $worker->connected is too much expensive since is over HTTP, prefer dead
    #       (shuffle avoids starvation if a free worker keeps failing)
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
        log_debug "need to schedule " . scalar(@$tobescheduled) . " jobs for $j->{id}($j->{priority})";
        next if defined $allocated_jobs->{$j->{id}};
        next unless $tobescheduled;
        my %taken;
        for my $sub_job (sort { $a->{id} <=> $b->{id} } @$tobescheduled) {
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

    for my $allocated (values %$allocated_jobs) {
        #  Now we need to set the worker in the job, with the state in SCHEDULED.
        my $job;
        my $worker;
        try {
            $job = $schema->resultset("Jobs")->find({id => $allocated->{job}});
        }
        catch {
            log_debug("Failed to retrieve Job(" . $allocated->{job} . ") in the DB :( bummer! Reason: $_");
        };

        try {
            $worker = $schema->resultset("Workers")->find({id => $allocated->{worker}});
        }
        catch {
            log_debug("Failed to retrieve Worker(" . $allocated->{worker} . ") in the DB :( bummer! Reason: $_");
        };

        next unless $job && $worker;
        if ($worker->job) {
            log_debug "Worker already got a job, skipping";
            next;
        }
        if ($job->state ne SCHEDULED) {
            log_debug "Job no longer scheduled, skipping";
            next;
        }
        my $res;
        try {
            $res = $job->ws_send($worker);    # send the job to the worker
            die "Failed contacting websocket server over HTTP" unless ref($res) eq "HASH" && exists $res->{state};
        }
        catch {
            log_debug("Failed to send data to websocket :( bummer! Reason: $_");
        };

        # We succeded dispatching the message
        if (ref($res) eq "HASH" && $res->{state}->{msg_sent} == 1) {
            log_debug("Sent job '" . $allocated->{job} . "' to worker '" . $allocated->{worker} . "'");
            my $scheduled_state;
            try {
                # We associate now the worker to the job, so the worker can send updates.
                if ($job->set_assigned_worker($worker)) {
                    push(@successfully_allocated, {job => $allocated->{job}, worker => $allocated->{worker}});
                }
                else {
                    # Send abort and reschedule if we fail associating the job to the worker
                    die "Failed rollback of job" unless $job->reschedule_rollback($worker);
                }
            }
            catch {
                log_debug("Failed to set worker in scheduling state :( bummer! Reason: $_");
            };

        }
        else {
            log_debug("Failed sending job '" . $allocated->{job} . "' to worker '" . $allocated->{worker});

            try {
                $worker->unprepare_for_work;
            }
            catch {
                log_debug("Failed resetting unprepare worker :( bummer! Reason: $_");
            };

            try {
                # Remove the associated worker and be sure to be in scheduled state.
                die "Failed reset" unless $job->reschedule_state;
            }
            catch {
                # Again: If we see this, we are in a really bad state.
                log_debug("Failed resetting job '$allocated->{id}' to scheduled state :( bummer! Reason: $_");
            };
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

    return if $taken->{$j->{id}};
    # if we were called with undef, this is a sign that
    # the cluster is not fully scheduled (e.g. blocked_by), so
    # take that as mark but return
    $taken->{$j->{id}} = $j;

    my $ci = $j->{cluster_jobs}->{$j->{id}};
    return unless $ci;
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

1;
