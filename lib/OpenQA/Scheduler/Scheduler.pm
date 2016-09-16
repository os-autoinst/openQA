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
use Data::Dump qw/dd pp/;
use Date::Format qw/time2str/;
use DBIx::Class::Timestamps qw/now/;
use DateTime;
use File::Spec::Functions qw/catfile catdir/;
use File::Temp qw/tempdir/;
use Mojo::URL;
use Try::Tiny;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use OpenQA::Utils qw/log_debug log_warning parse_assets_from_settings asset_type_from_setting/;
use db_helpers qw/rndstr/;

use OpenQA::IPC;

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register job_create
  job_grab job_set_done job_set_waiting job_set_running job_notify_workers
  job_restart
  job_set_stop job_stop iso_stop_old_builds
  asset_list asset_get asset_delete asset_register
);

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
sub job_notify_workers {
    # notify workers about new job
    my $ipc = OpenQA::IPC->ipc;
    $ipc->websockets('ws_send_all', 'job_available');
}

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

    return ({'-in' => $available_children->get_column('child_job_id')->as_query}) if ($available_children->count() > 0);    # we have scheduled children that are not blocked

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

        return ({'-in' => $available_parents->get_column('parent_job_id')->as_query}) if ($available_parents->count() > 0);

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

sub job_grab {
    my %args       = @_;
    my $workerid   = $args{workerid};
    my $blocking   = int($args{blocking} || 0);
    my $workerip   = $args{workerip};
    my $workercaps = $args{workercaps};

    my $worker = _validate_workerid($workerid);
    if ($worker->job) {
        # TROUBLE ahead - do not call seen, to get into dead worker detection first
        log_warning($worker->name . " still has a job, but wants to grab new one: " . $worker->job->id);
        return {};
    }
    $worker->seen($workercaps);

    my $result;
    while (1) {
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

        # now query for the best
        my $job = schema->resultset("Jobs")->search(
            {
                state => OpenQA::Schema::Result::Jobs::SCHEDULED,
                id    => \@available_cond,
            },
            {order_by => {-asc => [qw/priority id/]}})->first;
        if ($job) {
            # we do this in a transaction to avoid the same job being assigned
            # to two workers - the 2nd worker will fail the unique constraint in
            # the workers table and the throw an exception - and re-grab
            try {
                schema->txn_do(
                    sub {
                        $job->update(
                            {
                                state     => OpenQA::Schema::Result::Jobs::RUNNING,
                                t_started => now(),
                            });
                        $worker->job($job);
                        $worker->update;
                    });
            }
            catch {
                # this job is most likely already taken
                warn "Failed to grab job: $_";
                next;
            };
            last;
        }
        last unless $blocking;
        # XXX: do something smarter here
        #print STDERR "no jobs for me, sleeping\n";
        #sleep 1;
        last;
    }

    my $job = $worker->job;
    return {} unless ($job && $job->state eq OpenQA::Schema::Result::Jobs::RUNNING);

    my $job_hashref = {};
    $job_hashref = $job->to_hash(assets => 1);

    $worker->set_property('INTERACTIVE_REQUESTED',        0);
    $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', 0);

    # JOBTOKEN for test access to API
    my $token = rndstr;
    $worker->set_property('JOBTOKEN', $token);
    $job_hashref->{settings}->{JOBTOKEN} = $token;

    my $updated_settings = $job->register_assets_from_settings();

    if ($updated_settings) {
        for my $k (keys %$updated_settings) {
            $job_hashref->{settings}->{$k} = $updated_settings->{$k};
        }
    }
    # else assets are broken, maybe we could cancel the job right now

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
    job_notify_workers() if $job->children->count();

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
    my $jobid = shift;

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

=head2 job_duplicate

=over

=item Arguments: HASH { jobid => SCALAR, dup_type_auto => SCALAR, retry_avbl => SCALAR }

=item Return value: ID of new job

=back

Handle individual job restart including associated job and asset dependencies

=cut
sub job_duplicate {
    my %args = @_;
    # set this clone was triggered by manually if it's not auto-clone
    $args{dup_type_auto} = 0 unless defined $args{dup_type_auto};

    my $job = schema->resultset("Jobs")->find({id => $args{jobid}});
    return unless $job;

    if ($args{dup_type_auto}) {
        if (int($job->retry_avbl) > 0) {
            $args{retry_avbl} = int($job->retry_avbl) - 1;
        }
        else {
            log_debug("Could not auto-duplicated! The job are auto-duplicated too many times. Please restart the job manually.");
            return;
        }
    }
    else {
        if (int($job->retry_avbl) > 0) {
            $args{retry_avbl} = int($job->retry_avbl);
        }
        else {
            $args{retry_avbl} = 1;    # set retry_avbl back to 1
        }
    }

    my %clones = $job->duplicate(\%args);
    unless (%clones) {
        log_debug('duplication failed');
        return;
    }
    my @originals = keys %clones;
    # abort jobs restarted because of dependencies (exclude the original $args{jobid})
    my $jobs = schema->resultset("Jobs")->search(
        {
            id    => {'!=' => $job->id, '-in' => \@originals},
            state => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        },
        {
            colums => [qw/id/]});

    $jobs->search(
        {
            result => OpenQA::Schema::Result::Jobs::NONE,
        }
      )->update(
        {
            result => OpenQA::Schema::Result::Jobs::PARALLEL_RESTARTED,
        });

    while (my $j = $jobs->next) {
        next unless $j->worker;
        log_debug("enqueuing abort for " . $j->id . " " . $j->worker_id);
        $j->worker->send_command(command => 'abort', job_id => $j->id);
    }

    log_debug('new job ' . $clones{$job->id});
    job_notify_workers();
    return $clones{$job->id};
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
        },
        {
            columns => [qw/id/],
        });

    my @duplicated;
    while (my $j = $jobs->next) {
        my $id = job_duplicate(jobid => $j->id);
        push @duplicated, $id if $id;
    }

    # then tell workers to abort
    $jobs = schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        },
        {
            colums => [qw/id/],
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

    job_notify_workers();
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

sub asset_get {
    my %args = @_;
    my %cond;
    my %attrs;

    if (defined $args{id}) {
        $cond{id} = $args{id};
    }
    elsif (defined $args{type} && defined $args{name}) {
        $cond{name} = $args{name};
        $cond{type} = $args{type};
    }
    else {
        return;
    }

    return schema->resultset("Assets")->search(\%cond, \%attrs);
}

sub asset_delete {
    my $asset = asset_get(@_);
    return unless $asset;
    return $asset->delete;
}

sub asset_register {
    my %args = @_;

    my $type = $args{type} // '';

    unless ($OpenQA::Schema::Result::Assets::types{$type}) {
        warn "asset type '$type' invalid";
        return;
    }
    my $name = $args{name} // '';
    unless ($name && $name =~ /^[0-9A-Za-z+-._]+$/ && -e join('/', $OpenQA::Utils::assetdir, $type, $name)) {
        warn "asset name '$name' invalid or does not exist";
        return;
    }
    my $asset = schema->resultset("Assets")->find_or_create(
        {
            type => $type,
            name => $name,
        },
        {
            key => 'assets_type_name',
        });
    return $asset;
}

1;
# vim: set sw=4 et:
