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
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use Scalar::Util 'weaken';
use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use OpenQA::Utils qw(log_debug log_warning send_job_to_worker is_job_allocated);
use db_helpers 'rndstr';
use Time::HiRes 'time';
use List::Util 'shuffle';
use OpenQA::IPC;
use sigtrap handler => \&normal_signals_handler, 'normal-signals';
use OpenQA::Scheduler;

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register job_create
  job_grab job_set_done job_set_waiting job_set_running
  job_restart
  job_set_stop job_stop iso_stop_old_builds
  asset_list
);

CORE::state $failure           = 0;
CORE::state $ws_allocated_jobs = {};
CORE::state $keepalives        = {};
CORE::state $quit              = 0;

sub normal_signals_handler {
    log_debug("Received signal to stop");
    $quit++;
    _reschedule(1, 1);
}

sub wakeup_scheduler {
    log_debug("I've been summoned by the webui");
    _reschedule(OpenQA::Scheduler::SCHEDULE_TICK_MS()) if OpenQA::Scheduler::WAKEUP_ON_REQUEST();
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

sub _validate_workerid($) {
    my $workerid = shift;
    die "invalid worker id\n" unless $workerid;
    my $rs = schema->resultset("Workers")->find($workerid);
    die "invalid worker id $workerid\n" unless $rs;
    return $rs;
}

#
# Jobs API
#
sub _prefer_parallel {
    my ($available_cond) = @_;
    my $running = schema->resultset("Jobs")->search(
        {
            state => OpenQA::Schema::Result::Jobs::RUNNING,
        })->get_column('id')->as_query;

    # get scheduled children of running jobs
    my $children = schema->resultset("JobDependencies")->search(
        {
            dependency    => OpenQA::Schema::Result::JobDependencies::PARALLEL,
            parent_job_id => {-in => $running},
            state         => OpenQA::Schema::Result::Jobs::SCHEDULED
        },
        {
            join => 'child',
        });

    return if ($children->count() == 0);    # no scheduled children, whole group is running

    my $available_children = $children->search(
        {
            child_job_id => $available_cond
        });

    # we have scheduled children that are not blocked
    return ({'-in' => $available_children->get_column('child_job_id')->as_query})
      if ($available_children->count() > 0);

    # children are blocked, we have to find and start their parents first
    my $parents = schema->resultset("JobDependencies")->search(
        {
            dependency   => OpenQA::Schema::Result::JobDependencies::PARALLEL,
            child_job_id => {-in => $children->get_column('child_job_id')->as_query},
            state        => OpenQA::Schema::Result::Jobs::SCHEDULED,
        },
        {
            join => 'parent',
        });

    while ($parents->count() > 0) {

        my $available_parents = $parents->search(
            {
                parent_job_id => $available_cond
            });

        return ({'-in' => $available_parents->get_column('parent_job_id')->as_query})
          if ($available_parents->count() > 0);

        # parents are blocked, lets check grandparents
        $parents = schema->resultset("JobDependencies")->search(
            {
                dependency   => OpenQA::Schema::Result::JobDependencies::PARALLEL,
                child_job_id => {-in => $parents->get_column('parent_job_id')->as_query},
                state        => OpenQA::Schema::Result::Jobs::SCHEDULED,
            },
            {
                join => 'parent',
            });
    }
    return;
}

=head2 schedule()

Have no arguments. It's called by the main event loop every SCHEDULE_TICK_MS.
If BUSY_BACKOFF or CONGESTION_CONTROL are enabled this is not granted
and the tick will be dynamically adjusted according to errors occurred while
performing operations (CONGESTION_CONTROL) or when we are overloaded (BUSY_BACKOFF).

=cut

sub schedule {
    my $allocated_worker;
    my $start_time = time;

    log_debug("+=" . ("-" x 16) . "=+");
    log_debug("Check if previously dispatched jobs(" . scalar(keys %{$ws_allocated_jobs}) . ") were accepted");

    # If in the other tick we allocated some job,
    # let's check if meanwhile we got an answer from the worker replying it have accepted.
    # While doing that, we also cleanup the websocket
    # queue that keeps the accepted messages.

    foreach my $j (keys %{$ws_allocated_jobs}) {
        my $workerid          = is_job_allocated($j);                             # Delete from the queue
        my $expected_workerid = $ws_allocated_jobs->{$j}->{assigned_worker_id};
        my $can_retry = $ws_allocated_jobs->{$j}->{retries} < OpenQA::Scheduler::RETRY_JOB_ALLOCATION_ATTEMPTS();

        log_debug("[Job#${j}] Check if was accepted by the assigned worker $expected_workerid :"
              . pp($ws_allocated_jobs->{$j}));

        my $job = schema->resultset("Jobs")->find({id => $j});
        if ($expected_workerid == $workerid) {
            log_debug("[Job#${j}] Accepted by the assigned worker $expected_workerid");

            try {
                delete $ws_allocated_jobs->{$j};
                die "Already updated state"
                  unless $job->set_running;    #avoids to reset the state if the worker killed the job immediately
                log_debug("[Job#${j}] Accepted by worker $expected_workerid - setted to running state");
            }
            catch {
                log_debug("[Job#${j}] Cannot set job to running state for worker $expected_workerid, reason: " . $_);

                # Aborts and set the job to scheduled again
                $job->reschedule_rollback if $job->result eq OpenQA::Schema::Result::Jobs::NONE;

                # Either we had a real failure or the system is under load.
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF();
            };
        }
        elsif ($can_retry) {
            $ws_allocated_jobs->{$j}->{retries}++;

            log_debug("[Job#${j}] [Attempt#"
                  . $ws_allocated_jobs->{$j}->{retries}
                  . "] Still no message back from Worker $expected_workerid - ");
        }
        else {
            log_debug(
                    "[Job#${j}] Too bad, the job was not accepted by the worker. Maximum number of retrials exceeded ("
                  . OpenQA::Scheduler::RETRY_JOB_ALLOCATION_ATTEMPTS()
                  . ")");

            $job->reschedule_rollback;

            delete $ws_allocated_jobs->{$j};

            # If we had a different accept, possibly means
            # we are really congested by the messages coming from different workers
            # that we allocated in a "burst" of scheduling
            $failure++
              if OpenQA::Scheduler::CONGESTION_CONTROL();
        }

    }

    # Avoid to go into starvation - reset the scheduler tick counter.
    reactor->{timer}->{capture_loop_avoidance} ||= reactor->add_timeout(
        OpenQA::Scheduler::CAPTURE_LOOP_AVOIDANCE(),
        Net::DBus::Callback->new(
            method => sub {
                return if $failure == 0;
                $failure = 0;
                log_debug("[Congestion control] Resetting failures count. Next scheduler round will be reset to "
                      . OpenQA::Scheduler::SCHEDULE_TICK_MS()
                      . "ms");
                _reschedule(
                    OpenQA::Scheduler::BUSY_BACKOFF() ?
                      OpenQA::Scheduler::SCHEDULE_TICK_MS() + 1000
                    : OpenQA::Scheduler::SCHEDULE_TICK_MS());
            })) if (OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF());

    # Keepalives reset
    reactor->{timer}->{keepalive_reset} ||= reactor->add_timeout(
        (OpenQA::Scheduler::CAPTURE_LOOP_AVOIDANCE()) / 2,
        Net::DBus::Callback->new(
            method => sub {
                $keepalives = {};
                log_debug("[Keepalives] Resetting count");

            })) if OpenQA::Scheduler::KEEPALIVE_DEAD_WORKERS();

    # Exit only when database state is consistent.
    if ($quit) {
        log_debug("Exiting");
        exit(0);
    }

    my @allocated_jobs;

    log_debug("-> Scheduling new jobs.");
    try {
        @allocated_jobs = schema->txn_do(
            sub {
                my $all_workers = schema->resultset("Workers")->count();
                my @allocated_workers;
                my @allocated_jobs;
                my %free_workers_id;

                # NOTE: $worker->connected is too much expensive since is over dbus, prefer dead.
                my @free_workers = grep { !$_->dead } schema->resultset("Workers")->search({job_id => undef})->all();

                @free_workers = shuffle(@free_workers)
                  if OpenQA::Scheduler::SHUFFLE_WORKERS();   # shuffle avoids starvation if a free worker keeps failing.

                %free_workers_id = map { $_->id() => 1 } @free_workers;    # keep a hash of worker ids

                log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");
                log_debug("\t Failure# ${failure}") if OpenQA::Scheduler::CONGESTION_CONTROL();

                # Get id of workers recorded in the keepalives hash.
                # We query the DB to check if they don't have any job assigned,
                # and we filter also them from the following that will be allocated
                my @possible_free_workers = grep { !$_->job_id && !exists $free_workers_id{$_->id} }
                  map { schema->resultset("Workers")->find($_) } keys %{$keepalives};

                log_debug("Possible dead worker (not seen from search query): " . $_->id) for @possible_free_workers;

                if (@free_workers == 0) {
                    # Consider it a failure when either BUSY_BACKOFF or CONGESTION_CONTROL is enabled
                    # so if there are no free workers but we still have
                    # workers registered, scheduler will kick in later.
                    $failure++
                      if ((OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF())
                        && $all_workers > 0);
                    return ();
                }

                my $allocating = {};
                for my $w (@free_workers, @possible_free_workers) {
                    next if !$w->id();
                    # Get possible jobs by priority that can be allocated
                    # by checking workers capabilities
                    my @possible_jobs = job_grab(
                        workerid     => $w->id(),
                        blocking     => 0,
                        allocate     => 0,
                        jobs         => OpenQA::Scheduler::MAX_JOB_ALLOCATION(),
                        max_attempts => OpenQA::Scheduler::FIND_JOB_ATTEMPTS());
                    log_debug("[Worker#" . $w->id() . "] Possible jobs to allocate: " . scalar(@possible_jobs));

                    my $allocated_job;
                    for my $p_job (@possible_jobs) {
                        # Do not pick if we already wanted to allocate this job
                        # to another worker
                        next if exists $p_job->{id} && exists $allocating->{$p_job->{id}};
                        # Stop if we already have the job
                        last if $allocated_job;
                        $allocated_job = $p_job;
                    }

                    $keepalives->{$w->id()}++
                      if OpenQA::Scheduler::KEEPALIVE_DEAD_WORKERS();    # Count the worker as seen recently.
                    next unless $allocated_job && exists $allocated_job->{id};

                    log_debug("[Worker#" . $w->id() . "] Among them, we have chosen job: " . $allocated_job->{id});
                    $allocated_job->{assigned_worker_id} = $w->id();     # Set the worker id

                    # TODO: we need to be sure job_grab is not returning the same job
                    # for different workers - for now do not push them into allocated array.
                    push(@allocated_jobs, $allocated_job) if !exists $allocating->{$allocated_job->{id}};
                    $allocating->{$allocated_job->{id}}++;    # Set as allocated in the current scheduling clock
                }
                return @allocated_jobs;
            });
    }
    catch {
        # we had a real failure
        $failure++ if OpenQA::Scheduler::CONGESTION_CONTROL();
    };


    # Cut the jobs if we have a limit set since we didn't performed any DB update yet
    @allocated_jobs = splice @allocated_jobs, 0, OpenQA::Scheduler::MAX_JOB_ALLOCATION()
      if (OpenQA::Scheduler::MAX_JOB_ALLOCATION() > 0
        && scalar(@allocated_jobs) > OpenQA::Scheduler::MAX_JOB_ALLOCATION());

    my $successfully_allocated = 0;

    foreach my $allocated (@allocated_jobs) {
        #  Now we need to set the worker in the job, with the state in SCHEDULED.
        my $job = schema->resultset("Jobs")->find({id => $allocated->{id}});
        my $worker = schema->resultset("Workers")->find({id => $allocated->{assigned_worker_id}});
        my $res;
        try {
            $res = $job->ws_send($worker);    # send the job to the worker
        }
        catch {
            log_debug("Failed to send data to websocket :( bummer! Reason: $_");

            # If we fail during dispatch to dbus service
            # it's possible that websocket server is under heavy load.
            # Hence increment the counter in both modes
            $failure++
              if OpenQA::Scheduler::CONGESTION_CONTROL()
              || OpenQA::Scheduler::BUSY_BACKOFF();
        };

        # We succeded dispatching the message
        if (ref($res) eq "HASH" && $res->{state}->{msg_sent} == 1) {
            log_debug("Sent job '" . $allocated->{id} . "' to worker '" . $allocated->{assigned_worker_id} . "'");
            my $scheduled_state;
            try {
                # We associate now the worker to the job, so the worker can send updates.
                if ($job->set_scheduling_worker($worker)) {
                    $successfully_allocated++;

                    # Save it, in next round we will check if we got
                    # answer from the assigned worker and see what to do
                    $ws_allocated_jobs->{$allocated->{id}} = {
                        assigned_worker_id => $allocated->{assigned_worker_id},
                        result             => $allocated->{result},
                        retries            => 0
                    };
                }
                else {
                    # Send abort and reschedule if we fail associating the job to the worker
                    die "Failed rollback of job" unless $job->reschedule_rollback($worker);
                }
            }
            catch {
                log_debug("Failed to set worker in scheduling state :( bummer! Reason: $_");

                # If we see this, we are in a really bad state.
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::CONGESTION_CONTROL();
            };

        }
        else {
            log_debug("Failed sending job '"
                  . $allocated->{id}
                  . "' to worker '"
                  . $allocated->{assigned_worker_id} . "' : "
                  . pp($res));
            $failure++
              if OpenQA::Scheduler::CONGESTION_CONTROL()
              && OpenQA::Scheduler::BUSY_BACKOFF()
              ;    # We failed dispatching it. We might be under load, but it's not a big issue

            try {
                $worker->unprepare_for_work;
            }
            catch {
                log_debug("Failed resetting unprepare worker :( bummer! Reason: $_");
                # Again: If we see this, we are in a really bad state.
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF();
            };


            # put the job in scheduled state again.
            try {
                die "Failed reset" unless $job->reschedule_state;
            }
            catch {
                # Again: If we see this, we are in a really bad state.
                log_debug("Failed resetting job '$allocated->{id}' to scheduled state :( bummer! Reason: $_");
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF();
            };
        }
    }

    $failure--
      if $failure > 0
      && $successfully_allocated > 0
      && (OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF());

    my $elapsed_rounded = sprintf("%.5f", (time - $start_time));
    log_debug "Scheduler took ${elapsed_rounded}s to perform operations";

    # Decide if we want to reschedule ourselves or not.
    # we do that in two situations: either we had failures and CONGESTION_CONTROL is enabled,
    # or when we take too much time to perform the operations and either CONGESTION_CONTROL or BUSY_BACKOFF is enabled
    if (
        ($failure > 0 && OpenQA::Scheduler::CONGESTION_CONTROL())
        || (   (OpenQA::Scheduler::BUSY_BACKOFF() || OpenQA::Scheduler::CONGESTION_CONTROL())
            && ((int(${elapsed_rounded}) * 1000) > OpenQA::Scheduler::SCHEDULE_TICK_MS())))
    {
        my $backoff
          = OpenQA::Scheduler::CONGESTION_CONTROL()
          ?
          ((OpenQA::Scheduler::EXPBACKOFF()**($failure || 1)) - 1) * OpenQA::Scheduler::TIMESLOT()
          : ((($failure || 1) / OpenQA::Scheduler::EXPBACKOFF())**OpenQA::Scheduler::EXPBACKOFF())
          + OpenQA::Scheduler::SCHEDULE_TICK_MS();
        $backoff = $backoff > OpenQA::Scheduler::MAX_BACKOFF() ? OpenQA::Scheduler::MAX_BACKOFF() : $backoff + 1000;
        log_debug "[Congestion control] Calculated backoff: ${backoff}ms";
        log_debug "[Congestion control] Failures# ${failure}"
          if OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF();
        _reschedule($backoff, 1);
    }

    log_debug("+=" . ("-" x 16) . "=+");
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
    log_debug "[scheduler] Current tick is at ${current_interval}ms. New tick will be in: ${time}ms";
    reactor->remove_timeout(reactor->{timer}->{schedule_jobs});
    reactor->{timer}->{schedule_jobs} = reactor->add_timeout(
        $time,
        Net::DBus::Callback->new(
            method => \&OpenQA::Scheduler::Scheduler::schedule
        ));
}

sub _build_search_query {
    my $worker  = shift;
    my $blocked = schema->resultset("JobDependencies")->search(
        {
            -or => [
                -and => {
                    dependency => OpenQA::Schema::Result::JobDependencies::CHAINED,
                    state      => {-not_in => [OpenQA::Schema::Result::Jobs::FINAL_STATES]},
                },
                -and => {
                    dependency => OpenQA::Schema::Result::JobDependencies::PARALLEL,
                    state      => OpenQA::Schema::Result::Jobs::SCHEDULED,
                },
            ],
        },
        {
            join => 'parent',
        });
    my @available_cond = (    # ids available for this worker
        '-and',
        {
            -not_in => $blocked->get_column('child_job_id')->as_query
        },
    );

    # Don't kick off jobs if GRU task they depend on is running
    my $waiting_jobs = schema->resultset("GruDependencies")->get_column('job_id')->as_query;
    push @available_cond, {-not_in => $waiting_jobs};

    # list of jobs for different worker class
    # check the worker's classes
    my @classes = split /,/, ($worker->get_property('WORKER_CLASS') || '');

    if (@classes) {
        # check all worker classes of scheduled jobs and filter out those not applying
        my $scheduled = schema->resultset("Jobs")->search(
            {
                state => OpenQA::Schema::Result::Jobs::SCHEDULED
            })->get_column('id');

        my $not_applying_jobs = schema->resultset("JobSettings")->search(
            {
                job_id => {-in     => $scheduled->as_query},
                key    => 'WORKER_CLASS',
                value  => {-not_in => \@classes},
            },
            {distinct => 1})->get_column('job_id');

        push @available_cond, {-not_in => $not_applying_jobs->as_query};
    }

    my $preferred_parallel = _prefer_parallel(\@available_cond);
    push @available_cond, $preferred_parallel if $preferred_parallel;
    return @available_cond;
}


=head2 _job_allocate

Shortcut to allocate a job to a worker.
It accepts a worker id and a state to update along with the job.

=cut

sub _job_allocate {
    my $jobid    = shift;
    my $workerid = shift;
    my $state    = shift // OpenQA::Schema::Result::Jobs::RUNNING;

    my $job = schema->resultset("Jobs")->search(
        {
            id => $jobid,
        })->first;
    my $worker = schema->resultset("Workers")->search({id => $workerid})->first;


    if ($job && $worker) {
        $job->update(
            {
                state => $state,
                (t_started => now()) x !!($state eq OpenQA::Schema::Result::Jobs::RUNNING),
                assigned_worker_id => $worker->id,
            });
        $worker->job($job);
        $worker->update;
        log_debug("DB was updated to reflect system status") if $worker->job->id eq $job->id;
        return $worker || 0;
    }
    log_debug("Seems we really failed updating the DB status." . pp($job->to_hash));

    return 0;
}

=head2 job_grab

Search for matching jobs corresponding to a given worker id.
It accepts an hash as list of options.

  workerid     => $w->id(),

The ID of the worker that from its capabilities should match the job requirements.

  blocking     => 1

If enabled, will retry 999 times before returning no jobs available.

  allocate     => 1

If enabled it will allocate the job in the DB before returning the result.

  jobs         => 0

How many jobs at maximum have to be found: if set to 0 it will return all possible
jobs that can be allocated for the given worker

  max_attempts => 30

Maximum attempts to find a job.

=cut

sub job_grab {
    my %args     = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);
    my $allocate = int($args{allocate} || 0);
    my $job_n    = $args{jobs} // 0;

    my $worker;
    my $attempt = 0;
    my $matching_job;

    # Avoid to get the scheduler stuck: give a maximum limit of tries ($limit_attempts)
    # and blocking now just sets $max_attempts to 999.
    # Defaults to 1 (were observed in tests 2 is sufficient) before returning no jobs.
    my $limit_attempts = 2000;
    my @jobs;

    my $max_attempts
      = $blocking ?
      999
      : exists $args{max_attempts} ?
      (int($args{max_attempts}) < $limit_attempts && int($args{max_attempts}) > 0) ?
        int($args{max_attempts})
        : $limit_attempts
      : 1;

    try {
        $worker = _validate_workerid($workerid);

        if ($worker->job && $allocate) {
            my $job = $worker->job;
            log_warning($worker->name . " wants to grab a new job - killing the old one: " . $job->id);
            $job->done(result => 'incomplete');
            $job->auto_duplicate;
        }
        # NOTE: In the old scheduler logic we used to relay on job_grab also
        # to update workers capabilities. e.g. $worker->seen(%caps);
        # We do not update caps anymore on schedule. Instead, we just do this on registration.
        # That means if a worker change capabilities needs to be restarted.
    }
    catch {
        log_warning("Invalid worker id '$workerid'");
        return {};
    };

    do {
        $attempt++;
        log_debug("Attempt to find job $attempt/$max_attempts");

        # we do this in a transaction if job_grab
        # is called with the option 'allocate => 1'
        try {
            schema->txn_do(
                sub {
                    # Build the search query.
                    my $search = schema->resultset("Jobs")->search(
                        {
                            state => OpenQA::Schema::Result::Jobs::SCHEDULED,
                            id    => [_build_search_query($worker)],
                        },
                        {order_by => {-asc => [qw(priority id)]}});

                    # Depending on job_n:
                    # Get first n results, first result or all of them.
                    @jobs = $job_n > 0 ? $search->slice(0, $job_n) : $job_n == 0 ? $search->all() : ($search->first());

                    $worker = _job_allocate($jobs[0]->id, $worker->id(), OpenQA::Schema::Result::Jobs::RUNNING)
                      if ($allocate && $jobs[0]);

                });
        }
        catch {
            warn "Failed to grab job: $_";
        };

    } until (($attempt >= $max_attempts) || scalar(@jobs) > 0);

    # If we are not asked to allocate we just want the results of the search.
    # Check if we had more than one result, if we had:
    # convert them into hashrefs, otherwise return the single result
    # or none if any.

    return $job_n >= 0 ?
      @jobs ?
        map { $_->to_hash(assets => 1) } @jobs
        : ()
      : $jobs[0] ?
      $jobs[0]->to_hash(assets => 1)
      : {}
      unless ($allocate);
#return scalar(@jobs) == 0 ? () : $job_n!=1 ? map {$_->to_hash(assets => 1)} @jobs : $jobs[0] ?  $jobs[0]->to_hash(assets => 1) : {}  unless ($allocate);

    return {} unless ($worker && $worker->job && $worker->job->state eq OpenQA::Schema::Result::Jobs::RUNNING);

    my $job = $worker->job;
    log_debug("Got job " . $job->id());
    return $job->prepare_for_work($worker);
}

=head2 job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    # TODO: only allowed for running jobs
    my $r = schema->resultset("Jobs")->search(
        {
            id    => $jobid,
            state => OpenQA::Schema::Result::Jobs::RUNNING,
        }
      )->update(
        {
            state => OpenQA::Schema::Result::Jobs::WAITING,
        });
    return $r;
}

=head2 job_set_running

mark job as running. No error check. Meant to be called from worker!

=cut
sub job_set_running {
    my ($jobid) = @_;

    my $r = schema->resultset("Jobs")->search(
        {
            id    => $jobid,
            state => OpenQA::Schema::Result::Jobs::WAITING,
        }
      )->update(
        {
            state => OpenQA::Schema::Result::Jobs::RUNNING,
        });
    return $r;
}

=head2 job_restart

=over

=item Arguments: SCALAR or ARRAYREF of Job IDs

=item Return value: ARRAY of new job ids

=back

Handle job restart by user (using API or WebUI). Job is only restarted when either running
or done. Scheduled jobs can't be restarted.

=cut
sub job_restart {
    my ($jobids) = @_ or die "missing name parameter\n";

    # first, duplicate all jobs that are either running, waiting or done
    my $jobs = schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES, OpenQA::Schema::Result::Jobs::FINAL_STATES],
        });

    my @duplicated;
    while (my $j = $jobs->next) {
        my $job = $j->auto_duplicate;
        push @duplicated, $job->id if $job;
    }

    # then tell workers to abort
    $jobs = schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        });

    $jobs->search(
        {
            result => OpenQA::Schema::Result::Jobs::NONE,
        }
      )->update(
        {
            result => OpenQA::Schema::Result::Jobs::USER_RESTARTED,
        });

    while (my $j = $jobs->next) {
        log_debug("enqueuing abort for " . $j->id . " " . $j->worker_id);
        $j->worker->send_command(command => 'abort', job_id => $j->id);
    }
    wakeup_scheduler();
    return @duplicated;
}

#
# Assets API
#

sub asset_list {
    my %args = @_;

    my %cond;
    my %attrs;

    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page} || 0;

    if ($args{type}) {
        $cond{type} = $args{type};
    }

    return schema->resultset("Assets")->search(\%cond, \%attrs);
}

1;
# vim: set sw=4 et:
