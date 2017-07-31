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
use OpenQA::Utils qw(log_debug log_warning notify_workers send_job_to_worker is_job_allocated);
use db_helpers 'rndstr';
use Time::HiRes 'time';
use List::Util qw(shuffle);
use OpenQA::IPC;

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

sub schedule {
    my $allocated_worker;
    my $start_time = time;

    log_debug("+=" . ("-" x 16) . "=+");
    log_debug("Check if previously dispatched jobs(" . scalar(keys %{$ws_allocated_jobs}) . ") were accepted");

# If in the other tick we allocated some job, let's check meanwhile we got an answer from the worker, saying it have accepted it.

    foreach my $j (keys %{$ws_allocated_jobs}) {
        my $workerid = is_job_allocated($j);    # ask websocket server over dbus and remove from his 'queue'
        my $expected_workerid = $ws_allocated_jobs->{$j}->{assigned_worker_id};
        log_debug("[Job#${j}] Check if was accepted by the assigned worker $expected_workerid :"
              . pp($ws_allocated_jobs->{$j}));
        my $in_execution;

        my $job = schema->resultset("Jobs")->find({id => $j});

        if ($expected_workerid == $workerid) {
            #  my $worker = schema->resultset("Workers")->find({id => $workerid});
            $job->set_running;                  #avoids to reset the state if the worker killed the job immediately
                                                # $job->update(
                                                #     {
                                                #         state => OpenQA::Schema::Result::Jobs::RUNNING,
             #     }) if ($job->state eq OpenQA::Schema::Result::Jobs::SCHEDULED || $job->result eq OpenQA::Schema::Result::Jobs::NONE); #avoids to reset the state if the worker killed the job immediately
            log_debug("[Job#${j}] Accepted by worker $expected_workerid");

            #  $job->set_scheduling_worker($worker,);
        }
        else {
            log_debug("[Job#${j}] Too bad, seems wasn't accepted - sending abort to worker");

            $job->abort();    # TODO: this might become a problem if we have duplicated job IDs from 2 or more WebUI
                              #  OpenQA::IPC->ipc->websockets('ws_send', $expected_workerid, "abort", $j);
                              # Workers should be able to kill a job checking the (job token + job id) instead.
            $job->reschedule_state();

            $failure++
              if OpenQA::Scheduler::CONGESTION_CONTROL()
              && OpenQA::Scheduler::BUSY_BACKOFF();    # double it, we might be in a heavy load condition.
                                                       # Also, the workers could be massively in re-registration.
        }
    }
    $ws_allocated_jobs = {};

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
                _reschedule(OpenQA::Scheduler::SCHEDULE_TICK_MS());
            })) if (OpenQA::Scheduler::CONGESTION_CONTROL());

    my @allocated_jobs;

    log_debug("-> Scheduling new jobs.");
    try {
        @allocated_jobs = schema->txn_do(
            sub {
                my $all_workers = schema->resultset("Workers")->count();
                my @allocated_workers;
                my @allocated_jobs;

                # $worker->connected is too much expensive, prefeer dead.
                my @free_workers = grep { !$_->dead } schema->resultset("Workers")->search(
                    {job_id => undef},
                    #          ({rows => OpenQA::Scheduler::MAX_JOB_ALLOCATION()})
                    #          x !!(OpenQA::Scheduler::MAX_JOB_ALLOCATION() > 0)

                )->all();
                @free_workers = shuffle(@free_workers)
                  if OpenQA::Scheduler::SHUFFLE_WORKERS();   # shuffle avoids starvation if a free worker keeps failing.
                log_debug("\t Free workers: " . scalar(@free_workers) . "/$all_workers");
                log_debug("\t Failure# ${failure}") if OpenQA::Scheduler::CONGESTION_CONTROL();
                # Consider it a failure if OpenQA::Scheduler::CONGESTION_CONTROL is set
                # so if there are no free workers scheduler will kick in later.
                $failure++
                  and return ()
                  if @free_workers == 0
                  && OpenQA::Scheduler::CONGESTION_CONTROL()
                  && OpenQA::Scheduler::BUSY_BACKOFF()
                  && $all_workers > 0;

                for my $w (@free_workers) {
                    my $allocated_job = job_grab(
                        workerid     => $w->id(),
                        blocking     => 0,
                        allocate     => 0,
                        scheduler    => 1,
                        max_attempts => OpenQA::Scheduler::FIND_JOB_ATTEMPTS());
                    $allocated_job->{assigned_worker_id} = $w->id() if $allocated_job;
                    next unless $allocated_job && exists $allocated_job->{id};
                    push(@allocated_jobs, $allocated_job);
                }
                return @allocated_jobs;
            });
    }
    catch {
        # we had a real failure
        $failure++ if OpenQA::Scheduler::CONGESTION_CONTROL();
    };

    @allocated_jobs = splice @allocated_jobs, 0, OpenQA::Scheduler::MAX_JOB_ALLOCATION()
      if (OpenQA::Scheduler::MAX_JOB_ALLOCATION() > 0
        && scalar(@allocated_jobs) > OpenQA::Scheduler::MAX_JOB_ALLOCATION());

    my $successfully_allocated = 0;

    foreach my $allocated (@allocated_jobs) {
        #  Now we need to set  the worker in the job, with the state in SCHEDULED.

        my $job = schema->resultset("Jobs")->find({id => $allocated->{id}});
        my $worker = schema->resultset("Workers")->find({id => $allocated->{assigned_worker_id}});
        my $res;
        try {
            $res = $job->ws_send($worker);
        }
        catch {
            log_debug("Failed to send data to websocket :( bummer! Reason: $_");
            $failure++
              if OpenQA::Scheduler::CONGESTION_CONTROL()
              && OpenQA::Scheduler::BUSY_BACKOFF();    # double it, we might be in a heavy load condition.
                                                       # Also, the workers could be massively in re-registration.
        };

        if (ref($res) eq "HASH" && $res->{state}->{msg_sent} == 1) {
            log_debug("Sent job '" . $allocated->{id} . "' to worker '" . $allocated->{assigned_worker_id} . "'");
            my $scheduled_state;
            try {
                if ($job->set_scheduling_worker($worker)) {
                    $successfully_allocated++;
                    #Save it, in next round we will check if we got answer from worker and see what to do
                    $ws_allocated_jobs->{$allocated->{id}}
                      = {assigned_worker_id => $allocated->{assigned_worker_id}, result => $allocated->{result}};
                }
                else {
                    $job->abort();
                    $job->reschedule_state();
                }
            }
            catch {
                log_debug("Failed to set worker in scheduling state :( bummer! Reason: $_");
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL()
                  && OpenQA::Scheduler::BUSY_BACKOFF();    # double it, we might be in a heavy load condition.
                                                           # Also, the workers could be massively in re-registration.

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
              && OpenQA::Scheduler::BUSY_BACKOFF();    # We failed dispatching it. We might be under load

            try {
                $worker->unprepare_for_work;
            }
            catch {
                log_debug("Failed resetting unprepare worker :( bummer! Reason: $_");
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL()
                  && OpenQA::Scheduler::BUSY_BACKOFF();    # double it, we might be in a heavy load condition.
                                                           # Also, the workers could be massively in re-registration.
            };


            # put the job in scheduled state again.
            # we could search, dispatch the job and then update database in one transactions.
            # but it's better avoid to put ipc communication over dbus inside a transaction
            # (caused more-than-one complete sqlite database breakage locally)
            try {
                die "Failed reset" unless $job->reschedule_state;
            }
            catch {
                log_debug("Failed resetting job '$allocated->{id}' to scheduled state :( bummer! Reason: $_");
                $failure++
                  if OpenQA::Scheduler::CONGESTION_CONTROL()
                  && OpenQA::Scheduler::BUSY_BACKOFF();    # double it, we might be in a heavy load condition.
                                                           # Also, the workers could be massively in re-registration.
            };
        }
    }

    $failure--
      if $failure > 0
      && $successfully_allocated > 0
      && OpenQA::Scheduler::CONGESTION_CONTROL()
      && OpenQA::Scheduler::BUSY_BACKOFF();

    if ($failure > 0 && OpenQA::Scheduler::CONGESTION_CONTROL()) {
        my $backoff = ((OpenQA::Scheduler::EXPBACKOFF()**$failure) - 1) * OpenQA::Scheduler::TIMESLOT();
        log_debug "[Congestion control] Failures# ${failure} - Backoff period is : ${backoff}ms";
        _reschedule($backoff > OpenQA::Scheduler::MAX_BACKOFF() ? OpenQA::Scheduler::MAX_BACKOFF() : $backoff);
    }

    my $elapsed_rounded = sprintf("%.5f", (time - $start_time));
    log_debug("Scheduler took ${elapsed_rounded}s to perform operations");
    log_debug("+=" . ("-" x 16) . "=+");
}
#
# sub _reset_job {
#     my ($jobid, $workerid, $state) = @_;
#     $state //= OpenQA::Schema::Result::Jobs::SCHEDULED;
#     schema->txn_do(
#         sub {
#             my $job = schema->resultset("Jobs")->find({id => $jobid,});
#             my $worker = schema->resultset("Workers")->find({id => $workerid});
#             if ($job && $worker) {
#                 #  $job = _set_worker($job->id);    #unsets the worker
#
#                 $job->update(
#                     {
#                         state              => $state,
#                         t_started          => undef,
#                         assigned_worker_id => undef,
#                     });
#                 $worker->job(undef);
#                 $worker->update;
#                 if ($job->id() eq $jobid) {
#                     log_debug("Job '$jobid' reset to scheduled state");
#                 }
#                 else {
#                     log_debug("Job '$jobid' FAILED reset to scheduled state");
#                 }
#             }
#         });
# }

sub _reschedule {
    my $time             = shift;
    my $current_interval = reactor->{timeouts}->[reactor->{timer}->{schedule_jobs}]->{interval};
    return unless $current_interval != $time;
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

sub _get_job {
    my $worker = shift;
    return unless $worker;

    # we do this in a transaction to avoid the same job being assigned
    # to two workers - the 2nd worker will fail the unique constraint in
    # the workers table and the throw an exception - and re-grab

    return schema->txn_do(
        sub {
            # now query for the best

            return schema->resultset("Jobs")->search(
                {
                    state => OpenQA::Schema::Result::Jobs::SCHEDULED,
                    id    => [_build_search_query($worker)],
                },
                {order_by => {-asc => [qw(priority id)]}})->first;
        });

}

sub _job_allocate {
    my $jobid    = shift;
    my $workerid = shift;
    my $state    = shift // OpenQA::Schema::Result::Jobs::RUNNING;
    #    return schema->txn_do(
    #      sub {

    my $job = schema->resultset("Jobs")->search(
        {
            id => $jobid,
        })->first;
    my $worker = schema->resultset("Workers")->search({id => $workerid})->first;


    if ($job && $worker) {
        #  $worker = _set_worker($job->id, $worker->id);

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
    log_debug("Seems we really failed updating DB status." . pp($job->to_hash));

    return 0
      #
      #        });
}


sub job_grab {
    my %args     = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);
    #    my $workercaps = $args{workercaps};
    my $allocate = int($args{allocate} || 0);
    return {} unless $args{scheduler};

    my $worker;
    my $result;
    my $attempt = 0;
    my $matching_job;

    # Avoid to get the scheduler stuck: give a maximum limit of tries ($limit_attempts)
    # and blocking now just sets $max_attempts to 999.
    # Defaults to 1 (were observed in tests 2 is sufficient) before returning no jobs.
    my $limit_attempts = 2000;

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
        # $worker->seen(); # We do not update caps anymore on schedule. Instead, just do this on registration.
        # # That means if a worker change caps, needs to be restarted instead of posting them always.
        # }

    }
    catch {
        log_warning("Invalid worker id");
        return {};
    };


    do {
        $attempt++;
        log_debug("Attempt to find job $attempt/$max_attempts");

        # we do this in a transaction to avoid the same job being assigned
        # to two workers - the 2nd worker will fail the unique constraint in
        # the workers table and the throw an exception - and re-grab
        try {
            schema->txn_do(
                sub {
                    # now query for the best
                    $matching_job = _get_job($worker);
                    $worker = _job_allocate($matching_job->id, $worker->id(), OpenQA::Schema::Result::Jobs::RUNNING)
                      if ($matching_job && $allocate);
                });
        }
        catch {
            # this job is most likely already taken
            warn "Failed to grab job: $_";
        };

    } until (($attempt >= $max_attempts) || $matching_job);

    return $matching_job ? $matching_job->to_hash(assets => 1) : {} unless $allocate;

    my $job = $worker->job;
    return {} unless ($job && $job->state eq OpenQA::Schema::Result::Jobs::RUNNING);

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

    # if we got new jobs, notify workers
    # if (@duplicated) {
    #     notify_workers;
    # }
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
