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
use Scalar::Util qw(weaken isweak);
use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use OpenQA::Utils qw(log_debug log_warning notify_workers send_job_to_worker );
use db_helpers 'rndstr';

use OpenQA::IPC;

# How many jobs to allocate in one tick. Defaults to 0 (as much as possible)
use constant MAX_JOB_ALLOCATION => $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} // 0;

# How many attempts have to be performed to find a job before assuming there is nothing to be scheduled
use constant FIND_JOB_ATTEMPTS => $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS} // 5;

# Exp. backoff to avoid congestion.
# Enable it with 1, disable with 0. Following options depends on it.
use constant CONGESTION_CONTROL => $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL} // 1;

# Timeslot. Defaults to 15s
use constant TIMESLOT => $ENV{OPENQA_SCHEDULER_TIMESLOT} // 15000;

# Maximum backoff. Defaults to 360s
use constant MAX_BACKOFF => $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} // 360000;

# Our exponent, used to calculate backoff. Defaults to 2 (Binary)
use constant EXPBACKOFF => $ENV{OPENQA_SCHEDULER_EXP_BACKOFF} // 2;

# Timer reset to avoid starvation caused by congestion. Defaults to 660s
use constant CAPTURE_LOOP_AVOIDANCE => $ENV{OPENQA_SCHEDULER_CAPTURE_LOOP_AVOIDANCE} // 660000;

# set it to 1 if you want to backoff when no jobs can be assigned
use constant BUSY_BACKOFF => $ENV{OPENQA_SCHEDULER_BUSY_BACKOFF} // 0;

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

my $failure = 0;

sub reactor {
    my $react = shift;
    CORE::state $reactor;
    $reactor ||= $react;
    weaken $reactor if !isweak $reactor;
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
    my $allocated_job;
    my $allocated_worker;

    # Avoid to go into starvation
    reactor->{timer}->{capture_loop_avoidance} ||= reactor->add_timeout(
        CAPTURE_LOOP_AVOIDANCE,
        Net::DBus::Callback->new(
            method => sub {
                return if $failure == 0;
                $failure = 0;
                my $default_tick = OpenQA::Scheduler::SCHEDULE_TICK_MS();
                reactor->remove_timeout(reactor->{timer}->{schedule_jobs});
                reactor->{timer}->{schedule_jobs} = reactor->add_timeout(
                    $default_tick,
                    Net::DBus::Callback->new(
                        method => \&OpenQA::Scheduler::Scheduler::schedule
                    ));
                log_debug(
"[Congestion control] seems we had congestions before, resetting failures count to $failure and next scheduler round will be in $default_tick"
                );
            })) if (CONGESTION_CONTROL);

    my @allocated_jobs;
    try {
        @allocated_jobs = schema->txn_do(
            sub {
                my $all_workers = schema->resultset("Workers")->count();
                my @allocated_workers;
                my @allocated_jobs;
                my @free_workers = schema->resultset("Workers")
                  ->search({job_id => undef}, ({rows => MAX_JOB_ALLOCATION}) x !!(MAX_JOB_ALLOCATION > 0))->all();
                log_debug("Scheduler TICK. Free workers: " . scalar(@free_workers) . "/$all_workers");

                # Consider it a failure if CONGESTION_CONTROL is set
                # so if there are no free workers scheduler will kick in later.
                $failure++ and return ()
                  if @free_workers == 0 && CONGESTION_CONTROL && BUSY_BACKOFF && $all_workers > 0;

                for my $w (@free_workers) {
                    my %caps = $w->all_properties();
                    $allocated_job = job_grab(
                        workerid     => $w->id(),
                        blocking     => 0,
                        workercaps   => \%caps,
                        scheduler    => 1,
                        max_attempts => FIND_JOB_ATTEMPTS
                    );
                    next unless $allocated_job && exists $allocated_job->{id};
                    push(@allocated_jobs, $allocated_job);
                }
                return @allocated_jobs;

            });
    }
    catch {
        return unless (CONGESTION_CONTROL);
        # we had a failure
        $failure++;
    };

    if (@allocated_jobs > 0) {
        !!send_job_to_worker($_) && log_debug("Allocated job " . $_->{id} . " to worker " . $_->{assigned_worker_id})
          for @allocated_jobs;
        $failure-- if $failure > 0;
    }

    if ($failure > 0) {
        my $backoff = ((EXPBACKOFF**$failure) - 1) * TIMESLOT;
        log_debug
          "[Congestion control] Failed to schedule job. Failures#: ${failure}. Backoff period is : ${backoff}ms";
        _reschedule($backoff > MAX_BACKOFF ? MAX_BACKOFF : $backoff);
    }
}

sub _reschedule {
    my $time = shift;
    log_debug "[scheduler] New tick will be in: ${time}ms";
    reactor->remove_timeout(reactor->{timer}->{schedule_jobs});
    reactor->{timer}->{schedule_jobs} = reactor->add_timeout(
        $time,
        Net::DBus::Callback->new(
            method => \&OpenQA::Scheduler::Scheduler::schedule
        ));
}

sub job_grab {
    my %args       = @_;
    my $workerid   = $args{workerid};
    my $blocking   = int($args{blocking} || 0);
    my $workerip   = $args{workerip};
    my $workercaps = $args{workercaps};
    return {} unless $args{scheduler};

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

    my $worker = _validate_workerid($workerid);
    if ($worker->job) {
        my $job = $worker->job;
        log_warning($worker->name . " wants to grab a new job - killing the old one: " . $job->id);
        $job->done(result => 'incomplete');
        $job->auto_duplicate;
    }
    $worker->seen($workercaps);

    my $result;
    my $attempt = 0;
    my $job;
    do {
        $attempt++;
        log_debug("Attempt to find job $attempt/$max_attempts");

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

        # we do this in a transaction to avoid the same job being assigned
        # to two workers - the 2nd worker will fail the unique constraint in
        # the workers table and the throw an exception - and re-grab
        try {
            schema->txn_do(
                sub {
                    # now query for the best

                    $job = schema->resultset("Jobs")->search(
                        {
                            state => OpenQA::Schema::Result::Jobs::SCHEDULED,
                            id    => \@available_cond,
                        },
                        {order_by => {-asc => [qw(priority id)]}})->first;
                    if ($job) {
                        $job->update(
                            {
                                state              => OpenQA::Schema::Result::Jobs::RUNNING,
                                t_started          => now(),
                                assigned_worker_id => $workerid,
                            });
                        $worker->job($job);
                        $worker->update;
                    }
                });
        }
        catch {
            # this job is most likely already taken
            warn "Failed to grab job: $_";
        };

    } until (($attempt >= $max_attempts) || $job);

    $job = $worker->job;
    return {} unless ($job && $job->state eq OpenQA::Schema::Result::Jobs::RUNNING);
    log_debug("Got job " . $job->id());

    my $job_hashref = {};
    $job_hashref = $job->to_hash(assets => 1);

    $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', 0);

    # JOBTOKEN for test access to API
    my $token = rndstr;
    $worker->set_property('JOBTOKEN', $token);
    $job_hashref->{settings}->{JOBTOKEN} = $token;

    my $updated_settings = $job->register_assets_from_settings();

    @{$job_hashref->{settings}}{keys %$updated_settings} = @{$updated_settings}{keys %$updated_settings}
      if ($updated_settings);

    if (   $job_hashref->{settings}->{NICTYPE}
        && !defined $job_hashref->{settings}->{NICVLAN}
        && $job_hashref->{settings}->{NICTYPE} ne 'user')
    {
        my @networks = ('fixed');
        @networks = split /\s*,\s*/, $job_hashref->{settings}->{NETWORKS} if $job_hashref->{settings}->{NETWORKS};
        my @vlans;
        for my $net (@networks) {
            push @vlans, $job->allocate_network($net);
        }
        $job_hashref->{settings}->{NICVLAN} = join(',', @vlans);
    }

    # TODO: cleanup previous tmpdir
    $worker->set_property('WORKER_TMPDIR', tempdir());

    # starting one job from parallel group can unblock
    # other jobs from the group
    #notify_workers;

    return $job_hashref;
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
    if (@duplicated) {
        notify_workers;
    }
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
