# Copyright (C) 2013-2016 SUSE LLC
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

package OpenQA::Scheduler::Scheduler;

use strict;
use warnings;
use diagnostics;

# we need the critical fix for update
# see https://github.com/dbsrgits/dbix-class/commit/31160673f390e178ee347e7ebee1f56b3f54ba7a
use DBIx::Class 0.082801;

use DBIx::Class::ResultClass::HashRefInflator;
use Digest::MD5;
use Data::Dumper;
use Data::Dump qw(dd pp);
use Date::Format 'time2str';
use DBIx::Class::Timestamps 'now';
use DateTime;
use File::Temp 'tempdir';
use Mojo::URL;
use Try::Tiny;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use Scalar::Util 'weaken';
use FindBin;
use lib $FindBin::Bin;
use OpenQA::Utils qw(log_debug log_warning send_job_to_worker exists_worker);
use db_helpers 'rndstr';
use Time::HiRes 'time';
use List::Util qw(all shuffle);
use OpenQA::IPC;
use sigtrap handler => \&normal_signals_handler, 'normal-signals';
use OpenQA::Scheduler;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter);
@EXPORT = qw(job_grab);

CORE::state $summoned = 0;
CORE::state $quit     = 0;

my $shuffle_workers = 1;

sub shuffle_workers {
    my $want = shift;
    $shuffle_workers = $want;
    return $shuffle_workers;
}

sub normal_signals_handler {
    log_debug("Received signal to stop");
    $quit++;
    _reschedule(1, 1);
}

sub wakeup_scheduler {
    $summoned = 1;
    _reschedule(1);
}

=head2 reactor

Getter/Setter for the main Net::DBus::Reactor in the current loop:

  reactor($reactor);
  reactor->add_timeout();

=cut

sub reactor {
    CORE::state $reactor;
    return $reactor if $reactor;
    $reactor = shift;
    weaken $reactor;
    return $reactor;
}

sub schema {
    CORE::state $schema;
    $schema = OpenQA::Schema::connect_db() unless $schema;
    return $schema;
}

sub matching_workers {
    my ($job, $free_workers) = @_;

    my @classes = map { $_->value } $job->settings->search({key => 'WORKER_CLASS'})->all;

    my @filtered;
    for my $worker (@$free_workers) {
        my $matched_all = all { $worker->check_class($_) } @classes;
        push(@filtered, $worker) if $matched_all;
    }
    return \@filtered;
}

sub to_be_scheduled {
    my ($j, $scheduled) = @_;

    my $ci  = $j->{cluster_jobs}->{$j->{id}};
    my @ret = ($j);
    for my $s (@{$ci->{parallel_children}}) {
        return undef unless $scheduled->{$s};
        push(@ret, $scheduled->{$s});
    }
    for my $s (@{$ci->{parallel_parents}}) {
        return undef unless $scheduled->{$s};
        push(@ret, $scheduled->{$s});
    }
    return \@ret;
}

=head2 schedule()

Have no arguments. It's called by the main event loop every SCHEDULE_TICK_MS.

=cut

sub schedule {
    my $allocated_worker;
    my $start_time = time;

    # Exit only when database state is consistent.
    if ($quit) {
        log_debug("Exiting");
        exit(0);
    }

    my @allocated_jobs;

    my $all_workers = schema->resultset("Workers")->count();

    my @f_w = grep { !$_->dead && ($_->websocket_api_version() || 0) == WEBSOCKET_API_VERSION }
      schema->resultset("Workers")->search({job_id => undef})->all();

    # NOTE: $worker->connected is too much expensive since is over dbus, prefer dead.
    # shuffle avoids starvation if a free worker keeps failing.
    my @free_workers = $shuffle_workers ? shuffle(@f_w) : @f_w;

    if (@free_workers == 0) {
        return ();
    }

    log_debug("+=" . ("-" x 16) . "=+");
    log_debug("-> Scheduling new jobs.");
    log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");

    # Don't kick off jobs if GRU task they depend on is running
    my $waiting_jobs = schema->resultset("GruDependencies")->get_column('job_id')->as_query;

    my $jobs = schema->resultset("Jobs")->search(
        {
            blocked_by_id => undef,
            state         => OpenQA::Jobs::Constants::SCHEDULED,
            id            => {-not_in => $waiting_jobs},
        });

    my %scheduled_jobs;

    my %cluster_infos;
    while (my $job = $jobs->next) {
        my $info = $scheduled_jobs{$job->id} || {};
        #$info->{job} = $job;
        # for easier access
        $info->{id}               = $job->id;
        $info->{priority}         = $job->priority;
        $info->{state}            = $job->state;
        $info->{matching_workers} = matching_workers($job, \@free_workers);
        $info->{cluster_jobs}     = $cluster_infos{$job->id};

        if (!$info->{cluster_jobs} && $info->{matching_workers}) {
            $info->{cluster_jobs} = $job->cluster_jobs;
            # it's the same cluster for all, so share
            for my $j (%{$info->{cluster_jobs}}) {
                $cluster_infos{$j} = $info->{cluster_jobs};
            }
        }
        $scheduled_jobs{$job->id} = $info;
    }
    log_debug("\t Scheduled jobs: " . scalar(keys %scheduled_jobs));

    my @need;
    # now fetch the remaining job states of cluster jobs
    for my $jobinfo (values %scheduled_jobs) {
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            next if defined $scheduled_jobs{$j};
            push(@need, $j);
        }
    }

    my %clusterjobs;
    $jobs = schema->resultset('Jobs')->search({id => \@need, state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    while (my $j = $jobs->next) {
        $clusterjobs{$j->id} = $j->state;
    }

    # keep count on workers
    my $allocating = {};

    # first pick cluster jobs with running siblings (prio doesn't matter)
    for my $jobinfo (values %scheduled_jobs) {
        my $has_cluster_running = 0;
        for my $j (keys %{$jobinfo->{cluster_jobs}}) {
            if (defined $clusterjobs{$j}) {
                $has_cluster_running = 1;
                last;
            }
        }
        if ($has_cluster_running) {
            for my $w (@{$jobinfo->{matching_workers}}) {
                next if $allocating->{$w->id};
                $allocating->{$w->id} = $jobinfo->{id};
                push(@allocated_jobs, {job => $jobinfo->{id}, worker => $w->id});
            }
        }
    }

    my @sorted = sort { $a->{priority} <=> $b->{priority} || $a->{id} <=> $b->{id} } values %scheduled_jobs;
    for my $j (@sorted) {
        my $tobescheduled = to_be_scheduled($j, \%scheduled_jobs);
        next unless $tobescheduled;
        my %taken;
        for my $l (@$tobescheduled) {
            my $tw;
            for my $w (@{$l->{matching_workers}}) {
                next if $allocating->{$w->id};
                next if $taken{$w->id};
                $tw = $w;
                last;
            }
            if (!$tw) {
                %taken = ();
                last;
            }
            $taken{$tw->id} = $l;
        }
        for my $w (keys %taken) {
            my $l = $taken{$w};
            $allocating->{$w} = $l->{id};
            push(@allocated_jobs, {job => $l->{id}, worker => $w});
        }
        # we make sure we schedule clusters no matter what, but we stop if we're over
        # the limit
        last if scalar(keys %$allocating) >= OpenQA::Scheduler::MAX_JOB_ALLOCATION;
    }

    my @successfully_allocated;

    foreach my $allocated (@allocated_jobs) {
        #  Now we need to set the worker in the job, with the state in SCHEDULED.
        my $job;
        my $worker;
        try {
            $job = schema->resultset("Jobs")->find({id => $allocated->{job}});
        }
        catch {
            log_debug("Failed to retrieve Job(" . $allocated->{job} . ") in the DB :( bummer! Reason: $_");
        };

        try {
            $worker = schema->resultset("Workers")->find({id => $allocated->{worker}});
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

    if ($summoned || $quit) {
        log_debug("I've been summoned by the webui");
        $summoned = 0;
    }
    else {
        _reschedule(OpenQA::Scheduler::SCHEDULE_TICK_MS);
    }

    return (\@successfully_allocated);
}

=head2 _reschedule

Resets and set the new timer of when schedule() will be called.
It accepts a 2 variables: the time expressed in ms,
and a boolean that makes bypass constraints checks about rescheduling.

=cut

sub _reschedule {
    my ($time, $force) = @_;
    my $current_interval
      = reactor
      && reactor->{timeouts}
      && ref(reactor->{timeouts}) eq "ARRAY" ? reactor->{timeouts}->[reactor->{timer}->{schedule_jobs}]->{interval} : 0;
    return unless (reactor && (($current_interval != $time) || $force));
    log_debug "[rescheduling] Current tick is at ${current_interval}ms. New tick will be in: ${time}ms";
    reactor->remove_timeout(reactor->{timer}->{schedule_jobs});
    reactor->{timer}->{schedule_jobs} = reactor->add_timeout(
        $time,
        Net::DBus::Callback->new(
            method => \&OpenQA::Scheduler::Scheduler::schedule
        ));
}

1;
# vim: set sw=4 et:
