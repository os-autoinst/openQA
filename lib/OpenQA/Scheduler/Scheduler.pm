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
use List::Util 'shuffle';
use OpenQA::IPC;
use sigtrap handler => \&normal_signals_handler, 'normal-signals';
use OpenQA::Scheduler;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter);
@EXPORT = qw(job_grab);

CORE::state $failure    = 0;
CORE::state $no_actions = 0;
CORE::state $quit       = 0;

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

#
# Jobs API
#
sub _prefer_parallel {
    my ($available_cond, $allocating) = @_;
    my $running = schema->resultset("Jobs")->search(
        @$allocating > 0 ?
          {
            -or => [
                id    => {-in => $allocating},
                state => OpenQA::Jobs::Constants::RUNNING,
            ],
          }
        : {
            state => OpenQA::Jobs::Constants::RUNNING,
        })->get_column('id')->as_query;

    # get scheduled children of running jobs
    my $children = schema->resultset("JobDependencies")->search(
        {
            dependency    => OpenQA::Schema::Result::JobDependencies::PARALLEL,
            parent_job_id => {-in => $running},
            state         => OpenQA::Jobs::Constants::SCHEDULED
        },
        {
            join => 'child',
        });

    return if ($children->count() == 0);    # no scheduled children, whole group is running

    my $available_children = $children->search(
        {
            -and => [
                child_job_id => $available_cond,
                child_job_id => {-not_in => $allocating},
            ]});

    # we have scheduled children that are not blocked
    return ({'-in' => $available_children->get_column('child_job_id')->as_query})
      if ($available_children->count() > 0);

    # children are blocked, we have to find and start their parents first
    my $parents = schema->resultset("JobDependencies")->search(
        {
            dependency   => OpenQA::Schema::Result::JobDependencies::PARALLEL,
            child_job_id => {-in => $children->get_column('child_job_id')->as_query},
            state        => OpenQA::Jobs::Constants::SCHEDULED,
            child_job_id => {-not_in => $allocating},
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
                state        => OpenQA::Jobs::Constants::SCHEDULED,
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
    my $hard_busy  = (OpenQA::Scheduler::CONGESTION_CONTROL() || OpenQA::Scheduler::BUSY_BACKOFF());
    my $soft_busy  = (OpenQA::Scheduler::CONGESTION_CONTROL() && OpenQA::Scheduler::BUSY_BACKOFF());
    log_debug("+=" . ("-" x 16) . "=+");

    # Avoid to go into starvation - reset the scheduler tick counter.
    reactor->{timer}->{capture_loop_avoidance} ||= reactor->add_timeout(
        OpenQA::Scheduler::CAPTURE_LOOP_AVOIDANCE(),
        Net::DBus::Callback->new(
            method => sub {
                return if $failure == 0;
                $failure = 0;
                log_debug("[Congestion control] Resetting failures count and rescheduling if necessary");
                _reschedule(
                    OpenQA::Scheduler::BUSY_BACKOFF() ?
                      OpenQA::Scheduler::SCHEDULE_TICK_MS() + 1000
                    : OpenQA::Scheduler::SCHEDULE_TICK_MS());
            })) if $hard_busy;



    # Avoid to go into starvation - reset the scheduler tick counter.
    reactor->{timer}->{no_actions_reset} ||= reactor->add_timeout(
        OpenQA::Scheduler::CAPTURE_LOOP_AVOIDANCE(),
        Net::DBus::Callback->new(
            method => sub {
                return if $no_actions == 0;
                $no_actions = 0;
                log_debug("[Congestion control] Resetting no actions count and rescheduling if necessary");
                _reschedule(
                    OpenQA::Scheduler::BUSY_BACKOFF() ?
                      OpenQA::Scheduler::SCHEDULE_TICK_MS() + 1000
                    : OpenQA::Scheduler::SCHEDULE_TICK_MS());
            })) if $hard_busy;

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

                # NOTE: $worker->connected is too much expensive since is over dbus, prefer dead.
                # shuffle avoids starvation if a free worker keeps failing.
                my @free_workers
                  = shuffle(grep { !$_->dead && $_->get_websocket_api_version() == WEBSOCKET_API_VERSION }
                      schema->resultset("Workers")->search({job_id => undef})->all());

                log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");
                log_debug("\t Failure# ${failure}") if OpenQA::Scheduler::CONGESTION_CONTROL();

                if (@free_workers == 0) {
                    # Consider it a failure when either BUSY_BACKOFF or CONGESTION_CONTROL is enabled
                    # so if there are no free workers but we still have
                    # workers registered, scheduler will kick in later.
                    $failure++
                      if ($hard_busy && $all_workers > 0);
                    return ();
                }

                my $allocating = {};
                for my $w (@free_workers) {
                    next if !$w->id();
                    # Get possible jobs by priority that can be allocated
                    # by checking workers capabilities
                    my @possible_jobs = job_grab(
                        workerid     => $w->id(),
                        allocating   => [keys %$allocating],
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

                    next unless $allocated_job && exists $allocated_job->{id};

                    log_debug("[Worker#" . $w->id() . "] Among them, we have chosen job: " . $allocated_job->{id});
                    $allocated_job->{assigned_worker_id} = $w->id();    # Set the worker id

                    # TODO: we need to be sure job_grab is not returning the same job
                    # for different workers - for now do not push them into allocated array.
                    push(@allocated_jobs, $allocated_job) if !exists $allocating->{$allocated_job->{id}};
                    $allocating->{$allocated_job->{id}}++;    # Set as allocated in the current scheduling clock
                }
                return @allocated_jobs;
            });
    }
    catch {
        log_debug("Could not get new jobs to allocate: $_");
        # we had a real failure
        $failure++ if OpenQA::Scheduler::CONGESTION_CONTROL();
    };

    # Cut the jobs if we have a limit set since we didn't performed any DB update yet
    @allocated_jobs = splice @allocated_jobs, 0, OpenQA::Scheduler::MAX_JOB_ALLOCATION()
      if (OpenQA::Scheduler::MAX_JOB_ALLOCATION() > 0
        && scalar(@allocated_jobs) > OpenQA::Scheduler::MAX_JOB_ALLOCATION());

    # We filter after, or we risk to cut jobs that meant to be parallel later
    @allocated_jobs = filter_jobs(@allocated_jobs);

    my @successfully_allocated;

    foreach my $allocated (@allocated_jobs) {
        #  Now we need to set the worker in the job, with the state in SCHEDULED.
        my $job;
        my $worker;
        try {
            $job = schema->resultset("Jobs")->find({id => $allocated->{id}});
        }
        catch {
            log_debug("Failed to retrieve Job(" . $allocated->{id} . ") in the DB :( bummer! Reason: $_");

            $failure++
              if $soft_busy;
        };

        try {
            $worker = schema->resultset("Workers")->find({id => $allocated->{assigned_worker_id}});
        }
        catch {
            log_debug(
                "Failed to retrieve Worker(" . $allocated->{assigned_worker_id} . ") in the DB :( bummer! Reason: $_");

            $failure++
              if $soft_busy;
        };

        next unless $job && $worker;
        my $res;
        try {
            $res = $job->ws_send($worker);    # send the job to the worker
            die "Failed contacting websocket server over dbus" unless ref($res) eq "HASH" && exists $res->{state};
        }
        catch {
            log_debug("Failed to send data to websocket :( bummer! Reason: $_");

            # If we fail during dispatch to dbus service
            # it's possible that websocket server is under heavy load.
            # Hence increment the counter in both modes
            $failure++
              if $hard_busy;
        };

        # We succeded dispatching the message
        if (ref($res) eq "HASH" && $res->{state}->{msg_sent} == 1) {
            log_debug("Sent job '" . $allocated->{id} . "' to worker '" . $allocated->{assigned_worker_id} . "'");
            my $scheduled_state;
            try {
                # We associate now the worker to the job, so the worker can send updates.
                if ($job->set_assigned_worker($worker)) {
                    push(@successfully_allocated,
                        {job => $allocated->{id}, worker => $allocated->{assigned_worker_id}});
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
                  if $hard_busy;
            };

        }
        else {
            log_debug("Failed sending job '"
                  . $allocated->{id}
                  . "' to worker '"
                  . $allocated->{assigned_worker_id} . "' : "
                  . pp($res));
            $failure++
              if $soft_busy;    # We failed dispatching it. We might be under load, but it's not a big issue

            try {
                $worker->unprepare_for_work;
            }
            catch {
                log_debug("Failed resetting unprepare worker :( bummer! Reason: $_");
                # Again: If we see this, we are in a really bad state.
                $failure++
                  if $hard_busy;
            };

            try {
                # Remove the associated worker and be sure to be in scheduled state.
                die "Failed reset" unless $job->reschedule_state;
            }
            catch {
                # Again: If we see this, we are in a really bad state.
                log_debug("Failed resetting job '$allocated->{id}' to scheduled state :( bummer! Reason: $_");
                $failure++
                  if $hard_busy;
            };
        }
    }

    # update counters based on status
    $failure--
      if $failure > 0
      && scalar(@successfully_allocated) > 0
      && $hard_busy;

    $no_actions++
      if scalar(@successfully_allocated) == 0
      && $hard_busy;

    $no_actions = 0
      if $no_actions > 0
      && scalar(@successfully_allocated) > 0
      && $hard_busy;

    my $elapsed_rounded = sprintf("%.5f", (time - $start_time));
    log_debug "Scheduler took ${elapsed_rounded}s to perform operations and allocated "
      . scalar(@successfully_allocated) . " jobs";

    my $exceeded_timer = ((${elapsed_rounded} * 1000) > OpenQA::Scheduler::SCHEDULE_TICK_MS());
    if ($exceeded_timer && $hard_busy) {
        $failure += 2;
        log_debug "Scheduling took too much time. Increasing failure count. ($failure)";
    }
    log_debug "Allocated: " . pp($_) for @successfully_allocated;


    my $rescheduled;
    # Decide if we want to reschedule ourselves or not.
    # we do that in two situations: either we had failures and CONGESTION_CONTROL is enabled,
    # or when we take too much time to perform the operations and either CONGESTION_CONTROL or BUSY_BACKOFF is enabled
    if (
           ($no_actions > 0 && $hard_busy)
        || ($failure > 0 && OpenQA::Scheduler::CONGESTION_CONTROL())
        || (   $hard_busy
            && $exceeded_timer))
    {
        my $backoff
          = OpenQA::Scheduler::CONGESTION_CONTROL()
          ?
          ((2**(($failure + $no_actions) || 2)) - 1) * OpenQA::Scheduler::TIMESLOT()
          : (((($failure + $no_actions)  || 2) / 2)**2) + OpenQA::Scheduler::SCHEDULE_TICK_MS();
        $backoff = $backoff > OpenQA::Scheduler::MAX_BACKOFF() ? OpenQA::Scheduler::MAX_BACKOFF() : $backoff + 1000;
        log_debug "[Congestion control] Calculated backoff: ${backoff}ms";
        log_debug "[Congestion control] Rounds with no actions performed: ${no_actions}"
          if $hard_busy;
        log_debug "[Congestion control] Failures# ${failure}"
          if $hard_busy;
        _reschedule($backoff, 1);
        $rescheduled++;
    }

    log_debug("+=" . ("-" x 16) . "=+");
    return (\@successfully_allocated, $failure, $no_actions, $rescheduled);
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

sub _build_search_query {
    my ($worker, $allocating, $allocate) = @_;
    my $blocked = schema->resultset("JobDependencies")->search(
        {
            -or => [
                -and => {
                    dependency => OpenQA::Schema::Result::JobDependencies::CHAINED,
                    state      => {-not_in => [OpenQA::Jobs::Constants::FINAL_STATES]},
                },
                -and => {
                    dependency => OpenQA::Schema::Result::JobDependencies::PARALLEL,
                    state      => OpenQA::Jobs::Constants::SCHEDULED,
                    (parent_job_id => {-not_in => $allocating}) x !!(@$allocating > 0),
                }
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
    push @available_cond, {-not_in => $allocating} if @$allocating > 0;

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
                state => OpenQA::Jobs::Constants::SCHEDULED
            })->get_column('id');

        my $not_applying_jobs = schema->resultset("JobSettings")->search(
            {
                job_id => {-in => $scheduled->as_query},
                key    => 'WORKER_CLASS',
                value  => {-not_in => \@classes},
            },
            {distinct => 1})->get_column('job_id');

        push @available_cond, {-not_in => $not_applying_jobs->as_query};
    }

    my $preferred_parallel = _prefer_parallel(\@available_cond, $allocating);
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
    my $state    = shift // OpenQA::Jobs::Constants::RUNNING;

    my $job = schema->resultset("Jobs")->search(
        {
            id => $jobid,
        })->first;
    my $worker = schema->resultset("Workers")->search({id => $workerid})->first;


    if ($job && $worker) {
        $job->update(
            {
                state => $state,
                (t_started => now()) x !!($state eq OpenQA::Jobs::Constants::RUNNING),
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


sub filter_jobs {
    my @jobs          = @_;
    my @filtered_jobs = @jobs;
    my @delete;
    my $allocated_tests;
    my @k = qw(ARCH DISTRI BUILD FLAVOR);

    # TODO: @jobs's jobs needs to be a schema again
    # previously we didn't needed schema after scheduling phase
    # so we stripped down to what we needed

    try {
        my @running = map { $_->to_hash(assets => 1) }
          schema->resultset("Jobs")->search({state => OpenQA::Jobs::Constants::RUNNING})->all;

        # Build adjacent list with the tests that would have been assigned
        $allocated_tests->{$_->{test} . join(".", @{$_->{settings}}{@k})}++ for (@jobs, @running);

        foreach my $j (@jobs) {
            # Filter by PARALLEL_CLUSTER
            # next unless exists $j->{settings}->{PARALLEL_CLUSTER};

            my $dep = schema->resultset("Jobs")->search({id => $j->{id},})->first->dependencies;

            # Get dependencies - do not map with dbix, no oneline fun :(
            my @dep_tests;
            push(@dep_tests, schema->resultset("Jobs")->search({id => $_,})->first->TEST)
              for (@{$dep->{children}->{Parallel}}, @{$dep->{parents}->{Parallel}});

            # Filter if dependencies are not in the same allocation round
            @filtered_jobs = grep { $_->{id} ne $j->{id} } @filtered_jobs
              if grep { s/^\s+|\s+$//g; !exists $allocated_tests->{$_ . join(".", @{$j->{settings}}{@k})} } ## no critic
              (@dep_tests, exists $j->{settings}->{PARALLEL_WITH} ? split(/,/, $j->{settings}->{PARALLEL_WITH}) : ());
        }
    }
    catch {
        log_debug("Failed job filtering, error: " . $_);
        @filtered_jobs = @jobs;
    };

    return @filtered_jobs;
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
    my %args       = @_;
    my $workerid   = $args{workerid};
    my $blocking   = int($args{blocking} || 0);
    my $allocate   = int($args{allocate} || 0);
    my $job_n      = $args{jobs} // 0;
    my $allocating = $args{allocating} // [];

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
        $worker = exists_worker(schema(), $workerid);

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
                            state => OpenQA::Jobs::Constants::SCHEDULED,
                            id    => [_build_search_query($worker, $allocating, $allocate)],
                        },
                        {order_by => {-asc => [qw(priority id)]}});

                    # Depending on job_n:
                    # Get first n results, first result or all of them.
                    @jobs = $job_n > 0 ? $search->slice(0, $job_n) : $job_n == 0 ? $search->all() : ($search->first());

                    $worker = _job_allocate($jobs[0]->id, $worker->id(), OpenQA::Jobs::Constants::RUNNING)
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

    return {} unless ($worker && $worker->job && $worker->job->state eq OpenQA::Jobs::Constants::RUNNING);

    my $job = $worker->job;
    log_debug("Got job " . $job->id());
    return $job->prepare_for_work($worker);
}


1;
# vim: set sw=4 et:
