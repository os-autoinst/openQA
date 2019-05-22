# Copyright (C) 2015-2016 SUSE LLC
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

package OpenQA::Scheduler;
use Mojo::Base 'Mojolicious';

use OpenQA::Setup;
use Mojo::IOLoop;
use Data::Dump 'pp';
use DBIx::Class::Timestamps 'now';
use DateTime;
use Try::Tiny;
use OpenQA::Jobs::Constants;
use OpenQA::Utils qw(log_debug log_warning exists_worker);
use Time::HiRes 'time';
use List::Util qw(all shuffle);
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use Mojo::Server::Daemon;

# How many jobs to allocate in one tick. Defaults to 80 ( set it to 0 for as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 80;

# Scheduler default clock. Defaults to 20 s
# Optimization rule of thumb is:
# if we see a enough big number of messages while in debug mode stating "Congestion control"
# we might consider touching this value, as we may have a very large cluster to deal with.
# To have a good metric: you might raise it just above as the maximum observed time
# that the scheduler took to perform the operations
use constant SCHEDULE_TICK_MS => $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} // 20000;

my $SUMMONED = 0;
our $RUNNING;
my $shuffle_workers = 1;
my $SCHEDULED_JOBS  = {};

sub run {
    my $self   = __PACKAGE__->new;
    my $daemon = $self->setup;
    local $RUNNING = 1;
    $daemon->run;
}

sub setup {
    my $self = shift;

    my $setup = OpenQA::Setup->new(log_name => 'scheduler');
    OpenQA::Setup::read_config($setup);
    OpenQA::Setup::setup_log($setup);

    log_debug("Scheduler started");
    log_debug("\t Scheduler default interval(ms) : " . SCHEDULE_TICK_MS);
    log_debug("\t Max job allocation: " . MAX_JOB_ALLOCATION);

    # initial schedule
    schedule();
    Mojo::IOLoop->next_tick(sub { _reschedule() });

    return Mojo::Server::Daemon->new(app => $self);
}

sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Scheduler');
    $self->mode('production');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    my $r = $self->routes;
    $r->get(
        '/api/wakeup' => sub {
            my $c = shift;
            $SUMMONED = 1;
            _reschedule(0);
            $c->render(text => 'ok');
        });
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');
}

sub shuffle_workers {
    my $want = shift;
    $shuffle_workers = $want;
    return $shuffle_workers;
}

sub schedule {
    my $start_time = time;

    log_debug("I've been summoned by the webui") if $SUMMONED;

    my $schema      = OpenQA::Schema->singleton;
    my $all_workers = $schema->resultset("Workers")->count();

    my @f_w = grep { !$_->dead && ($_->websocket_api_version() || 0) == WEBSOCKET_API_VERSION }
      $schema->resultset("Workers")->search({job_id => undef, error => undef})->all();

    # NOTE: $worker->connected is too much expensive since is over HTTP, prefer dead
    #       (shuffle avoids starvation if a free worker keeps failing)
    my @free_workers = $shuffle_workers ? shuffle(@f_w) : @f_w;
    if (@free_workers == 0) {
        _conclude_scheduling();
        return ();
    }

    log_debug("+=" . ("-" x 16) . "=+");
    log_debug("-> Scheduling new jobs.");
    log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");

    _update_scheduled_jobs();
    log_debug("\t Scheduled jobs: " . scalar(keys %$SCHEDULED_JOBS));

    # update the matching workers to the current free
    for my $jobinfo (values %$SCHEDULED_JOBS) {
        $jobinfo->{matching_workers} = _matching_workers($jobinfo, \@free_workers);
    }

    my $allocated_jobs    = {};
    my $allocated_workers = {};

    # before we start looking at sorted jobs, we try to repair half
    # scheduled clusters. This can happen e.g. with workers connected to
    # multiple webuis
    _pick_siblings_of_running($allocated_jobs, $allocated_workers);

    my @sorted = sort { $a->{priority} <=> $b->{priority} || $a->{id} <=> $b->{id} } values %$SCHEDULED_JOBS;
    my %checked_jobs;
    for my $j (@sorted) {
        next if $checked_jobs{$j->{id}};
        next unless @{$j->{matching_workers}};
        my $tobescheduled = _to_be_scheduled($j, $SCHEDULED_JOBS);
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
            die "Failed contacting websocket server over dbus" unless ref($res) eq "HASH" && exists $res->{state};
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
    _conclude_scheduling();

    return (\@successfully_allocated);
}

# The reactor interval might be set to 1 ms in case the scheduler has been woken up by the
# web UI (In this case it is important to set it back to OpenQA::Scheduler::SCHEDULE_TICK_MS)
sub _conclude_scheduling {
    $SUMMONED = 0;
    _reschedule(SCHEDULE_TICK_MS);
}

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
    my ($allocated_jobs, $allocated_workers) = @_;

    my @need;
    # now fetch the remaining job states of cluster jobs
    for my $jobinfo (values %$SCHEDULED_JOBS) {
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            next if defined $SCHEDULED_JOBS->{$j};
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
    for my $jobinfo (values %$SCHEDULED_JOBS) {
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

sub _reschedule {
    my $time = shift;

    # Allow manual scheduling
    return unless $RUNNING;

    # Reuse the existing timer if possible
    state $interval = SCHEDULE_TICK_MS;
    my $current = $interval;
    $interval = $time //= $current;
    state $timer;
    return if $interval == $current && $timer;

    log_debug("[rescheduling] Current tick is at $current ms. New tick will be in: $time ms");
    Mojo::IOLoop->remove($timer) if $timer;
    $timer = Mojo::IOLoop->recurring(($interval / 1000) => sub { schedule() });
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

    # Don't kick off jobs if GRU task they depend on is running
    my $schema       = OpenQA::Schema->singleton;
    my $waiting_jobs = $schema->resultset("GruDependencies")->get_column('job_id')->as_query;

    my $jobs = $schema->resultset("Jobs")->search(
        {
            blocked_by_id => undef,
            state         => OpenQA::Jobs::Constants::SCHEDULED,
            id            => {-not_in => $waiting_jobs},
        });

    my %currently_scheduled;
    my %cluster_infos;
    my @missing_worker_class;
    while (my $job = $jobs->next) {
        # the priority_offset stays in the hash for the next round
        # and is increased whenever a cluster job has to give up its
        # worker because its siblings failed to find a worker on their
        # own. Once the combined priority reaches 0, the worker pick is sticky
        my $info = $SCHEDULED_JOBS->{$job->id} || {priority_offset => 0};
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
        $SCHEDULED_JOBS->{$job->id} = $info;
    }
    # fetch worker classes
    my $settings
      = $schema->resultset("JobSettings")->search({key => 'WORKER_CLASS', job_id => {-in => \@missing_worker_class}});
    while (my $line = $settings->next) {
        push(@{$SCHEDULED_JOBS->{$line->job_id}->{worker_classes}}, $line->value);
    }
    # delete stale entries
    for my $id (keys %$SCHEDULED_JOBS) {
        delete $SCHEDULED_JOBS->{$id} unless $currently_scheduled{$id};
    }
}

1;
