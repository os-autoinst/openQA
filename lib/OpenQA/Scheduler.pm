# Copyright (C) 2013-2015 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Scheduler;

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
use File::Temp qw/tempdir/;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use OpenQA::Utils qw/log_debug/;
use db_helpers qw/rndstr/;

use OpenQA::WebSockets;

use Mojo::IOLoop;

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register job_create
  job_get jobs_get_dead_worker
  job_grab job_set_done job_set_waiting job_set_running job_notify_workers
  job_delete job_update_result job_restart job_cancel command_enqueue
  iso_cancel_old_builds
  job_set_stop job_stop iso_stop_old_builds
  asset_list asset_get asset_delete asset_register
);


our %worker_commands = map { $_ => undef } qw/
  quit
  abort
  cancel
  obsolete
  stop_waitforneedle
  reload_needles_and_retry
  enable_interactive_mode
  disable_interactive_mode
  continue_waitforneedle
  job_available
  livelog_stop
  livelog_start
  /;

$worker_commands{enable_interactive_mode} = sub {
    my ($worker) = @_;
    $worker->set_property("INTERACTIVE_REQUESTED", 1);
};

$worker_commands{disable_interactive_mode} = sub {
    my ($worker) = @_;
    $worker->set_property("INTERACTIVE_REQUESTED", 0);
};

$worker_commands{stop_waitforneedle} = sub {
    my ($worker) = @_;
    $worker->set_property("STOP_WAITFORNEEDLE_REQUESTED", 1);
};

$worker_commands{continue_waitforneedle} = sub {
    my ($worker) = @_;
    $worker->set_property("STOP_WAITFORNEEDLE_REQUESTED", 0);
};

sub schema {
    CORE::state $schema;
    $schema = OpenQA::Schema::connect_db() unless $schema;
    return $schema;
}

=item _hashref()

Convert an ORM object into a hashref. The API only export hashes and
not ORM objects.

=cut

# XXX TODO - Remove this useless function when is not needed anymore
sub _hashref {
    my $obj    = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
        $hashref{$field} = $obj->$field;
    }

    return \%hashref;
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
    ws_send_all('job_available');
}

=item job_create

create a job

=cut
sub job_create {
    my ($settings, $no_notify) = @_;
    my %settings = %$settings;

    my %new_job_args = (test => $settings{TEST});

    if ($settings{NAME}) {
        my $njobs = schema->resultset("Jobs")->search({slug => $settings{NAME}})->count;
        return 0 if $njobs;

        $new_job_args{slug} = $settings{NAME};
        delete $settings{NAME};
    }

    if ($settings{_GROUP}) {
        $new_job_args{group} = {name => delete $settings{_GROUP}};
    }

    if ($settings{_START_AFTER_JOBS}) {
        for my $id (@{$settings{_START_AFTER_JOBS}}) {
            push @{$new_job_args{parents}},
              {
                parent_job_id => $id,
                dependency    => OpenQA::Schema::Result::JobDependencies::CHAINED,
              };
        }
        delete $settings{_START_AFTER_JOBS};
    }

    if ($settings{_PARALLEL_JOBS}) {
        for my $id (@{$settings{_PARALLEL_JOBS}}) {
            push @{$new_job_args{parents}},
              {
                parent_job_id => $id,
                dependency    => OpenQA::Schema::Result::JobDependencies::PARALLEL,
              };
        }
        delete $settings{_PARALLEL_JOBS};
    }

    while (my ($k, $v) = each %settings) {
        unless ($k eq 'WORKER_CLASS') {
            push @{$new_job_args{settings}}, {key => $k, value => $v};
            next;
        }
        for my $l (split(m/,/, $v)) {    # special case for worker class?
            push @{$new_job_args{settings}}, {key => $k, value => $l} if $l;
        }
    }

    my $job = schema->resultset("Jobs")->create(\%new_job_args);
    $OpenQA::Utils::app->gru->enqueue('limit_assets') if $OpenQA::Utils::app;

    job_notify_workers() unless $no_notify;
    return $job;
}

sub job_get($) {
    my $value = shift;

    return undef if !defined($value);

    if ($value =~ /^\d+$/) {
        return _job_get({'me.id' => $value});
    }
    return _job_get({slug => $value});
}

sub jobs_get_dead_worker {
    my $threshold = shift;

    my %cond = (
        'state'            => OpenQA::Schema::Result::Jobs::RUNNING,
        'worker.t_updated' => {'<' => $threshold},
    );
    my %attrs = (join => 'worker',);

    my $dead_jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);

    my @results = ();
    while (my $job = $dead_jobs->next) {
        my $j = _hashref($job, qw/ id state result worker_id/);
        push @results, $j;
    }

    return \@results;
}

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;
    my %attrs  = ();

    push @{$attrs{prefetch}}, 'settings';

    my $job = schema->resultset("Jobs")->search($search, \%attrs)->first;
    return undef unless $job;
    return $job->to_hash(assets => 1);
}

sub query_jobs {
    my %args = @_;

    my @conds;
    my %attrs;
    my @joins;

    unless ($args{idsonly}) {
        push @{$attrs{prefetch}}, 'settings';
        push @{$attrs{prefetch}}, 'parents';
        push @{$attrs{prefetch}}, 'children';
    }

    if ($args{state}) {
        push(@conds, {'me.state' => [split(',', $args{state})]});
    }
    if ($args{maxage}) {
        my $agecond = {'>' => time2str('%Y-%m-%d %H:%M:%S', time - $args{maxage}, 'UTC')};
        push(
            @conds,
            {
                -or => [
                    'me.t_created'  => $agecond,
                    'me.t_started'  => $agecond,
                    'me.t_finished' => $agecond
                ]});
    }
    if ($args{ignore_incomplete}) {
        push(@conds, {'me.result' => {-not_in => [OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS]}});
    }
    my $scope = $args{scope} || '';
    if ($scope eq 'relevant') {
        push(@joins, 'clone');
        push(
            @conds,
            {
                -or => [
                    'me.clone_id' => undef,
                    'clone.state' => [OpenQA::Schema::Result::Jobs::PENDING_STATES],
                ],
                'me.result' => {    # these results should be hidden by default
                    -not_in => [
                        OpenQA::Schema::Result::Jobs::OBSOLETED,
                        # OpenQA::Schema::Result::Jobs::USER_CANCELLED  I think USER_CANCELLED jobs should be available for restart
                    ]}});
    }
    if ($scope eq 'current') {
        push(@conds, {'me.clone_id' => undef});
    }
    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page} || 0;
    if ($args{assetid}) {
        push(@joins, 'jobs_assets');
        push(
            @conds,
            {
                'jobs_assets.asset_id' => $args{assetid},
            });
    }
    if (defined $args{groupid}) {
        push(
            @conds,
            {
                'me.group_id' => $args{groupid} || undef,
            });
    }
    elsif ($args{group}) {
        my $subquery = schema->resultset("JobGroups")->search({'name' => $args{group}})->get_column('id')->as_query;
        push(
            @conds,
            {
                'me.group_id' => {-in => $subquery},
            });
    }

    # Search into the following job_settings
    for my $setting (qw(build iso distri version flavor)) {
        if ($args{$setting}) {
            my $subquery = schema->resultset("JobSettings")->search(
                {
                    key   => uc($setting),
                    value => $args{$setting}});
            push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
        }
    }
    # Text search across some settings
    if ($args{match}) {
        my $subquery = schema->resultset("JobSettings")->search(
            {
                'key' => ['DISTRI', 'FLAVOR', 'BUILD', 'TEST', 'VERSION'],
                'value' => {'-like' => "%$args{match}%"},
            });
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }
    if ($args{ids}) {
        push(@conds, {'me.id' => {-in => $args{ids}}});
    }

    $attrs{order_by} = ['me.id DESC'];

    $attrs{join} = \@joins if @joins;
    my $jobs = schema->resultset("Jobs")->search({-and => \@conds}, \%attrs);
    return $jobs;
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

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab {
    my %args       = @_;
    my $workerid   = $args{workerid};
    my $blocking   = int($args{blocking} || 0);
    my $workerip   = $args{workerip};
    my $workercaps = $args{workercaps};

    my $worker = _validate_workerid($workerid);
    $worker->seen($workercaps);

    my $result;
    while (1) {
        my $blocked = schema->resultset("JobDependencies")->search(
            {
                -or => [
                    -and => {
                        dependency => OpenQA::Schema::Result::JobDependencies::CHAINED,
                        -or        => {
                            state  => {'!=', OpenQA::Schema::Result::Jobs::DONE},
                            result => {'!=', OpenQA::Schema::Result::Jobs::PASSED},
                        },
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

        my $worker = schema->resultset("Workers")->find($workerid);

        my @available_cond = (    # ids available for this worker
            '-and',
            {
                -not_in => $blocked->get_column('child_job_id')->as_query
            },
        );

        # list of jobs for different worker class

        # check the worker's classes
        my @classes = split /,/, ($worker->get_property('WORKER_CLASS') || '');

        if (@classes) {
            # check all worker classes of scheduled jobs and filter out those not applying
            my $scheduled = schema->resultset("Jobs")->search(
                {
                    'state'     => OpenQA::Schema::Result::Jobs::SCHEDULED,
                    'worker_id' => 0
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
                'state'     => OpenQA::Schema::Result::Jobs::SCHEDULED,
                'worker_id' => 0,
                id          => \@available_cond,
            },
            {order_by => {-asc => [qw/priority id/]}, rows => 1}
          )->update(
            {
                state     => OpenQA::Schema::Result::Jobs::RUNNING,
                worker_id => $workerid,
                t_started => now(),
            });

        last if $job;
        last unless $blocking;
        # XXX: do something smarter here
        #print STDERR "no jobs for me, sleeping\n";
        #sleep 1;
        last;
    }

    my $job = $worker->job;
    return {} unless ($job && $job->state eq OpenQA::Schema::Result::Jobs::RUNNING);

    my $job_hashref = {};
    $job_hashref = _job_get({'me.id' => $job->id});

    $worker->set_property('INTERACTIVE_REQUESTED',        0);
    $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', 0);

    # JOBTOKEN for test access to API
    my $token = rndstr;
    $worker->set_property('JOBTOKEN', $token);
    $job_hashref->{settings}->{JOBTOKEN} = $token;

    my $updated_settings = $job->assets_from_settings();

    if ($updated_settings) {
        for my $k (keys %$updated_settings) {
            $job_hashref->{settings}->{$k} = $updated_settings->{$k};
        }
    }
    # else assets are broken, maybe we could cancel the job right now

    # TODO: cleanup previous tmpdir
    $worker->set_property('WORKER_TMPDIR', tempdir());

    # starting one job from parallel group can unblock
    # other jobs from the group
    job_notify_workers() if $job->children->count();

    return $job_hashref;
}

# parent job failed, handle scheduled children - set them to done incomplete immediately
sub _job_skip_children {
    my $jobid = shift;

    my $children = schema->resultset("JobDependencies")->search(
        {
            dependency => {
                -in => [OpenQA::Schema::Result::JobDependencies::CHAINED, OpenQA::Schema::Result::JobDependencies::PARALLEL],
            },
            parent_job_id => $jobid,
        },
    );

    my $result = schema->resultset("Jobs")->search(
        {
            id    => {-in => $children->get_column('child_job_id')->as_query},
            state => OpenQA::Schema::Result::Jobs::SCHEDULED,
        },
      )->update(
        {
            state  => OpenQA::Schema::Result::Jobs::CANCELLED,
            result => OpenQA::Schema::Result::Jobs::SKIPPED,
        });

    while (my $j = $children->next) {
        my $id = $j->child_job_id;
        _job_skip_children($id);
    }
}

# parent job failed, handle running children - send stop command
sub _job_stop_children {
    my $jobid = shift;

    my $children = schema->resultset("JobDependencies")->search(
        {
            dependency    => OpenQA::Schema::Result::JobDependencies::PARALLEL,
            parent_job_id => $jobid,
        },
    );
    my $jobs = schema->resultset("Jobs")->search(
        {
            id    => {-in => $children->get_column('child_job_id')->as_query},
            state => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        },
    );

    $jobs->search(
        {
            result => OpenQA::Schema::Result::Jobs::NONE,
        }
      )->update(
        {
            result => OpenQA::Schema::Result::Jobs::PARALLEL_FAILED,
        });

    while (my $j = $jobs->next) {
        log_debug("enqueuing cancel for " . $j->id . " " . $j->worker_id);
        command_enqueue(workerid => $j->worker_id, command => 'cancel', job_id => $j->id);
        _job_stop_children($j->id);
    }
}

=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters
sub job_set_done {
    my %args = @_;
    return unless ($args{jobid});
    my $jobid    = int($args{jobid});
    my $newbuild = 0;
    $newbuild = int($args{newbuild}) if defined $args{newbuild};
    $args{result} = OpenQA::Schema::Result::Jobs::OBSOLETED if $newbuild;
    # delete JOBTOKEN
    my $job = schema->resultset('Jobs')->find($jobid);
    $job->set_property('JOBTOKEN');

    my $result = $args{result} || $job->calculate_result();
    my %new_val = (
        state      => OpenQA::Schema::Result::Jobs::DONE,
        worker_id  => 0,
        t_finished => now(),
    );

    # for cancelled jobs the result is already known
    $new_val{result} = $result if $job->result eq OpenQA::Schema::Result::Jobs::NONE;

    my $r;
    $r = $job->update(\%new_val);

    if ($result ne OpenQA::Schema::Result::Jobs::PASSED) {
        _job_skip_children($jobid);
        _job_stop_children($jobid);
    }
    return $r;
}

=item job_set_waiting

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

=item job_set_running

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

sub job_delete {
    my $value = shift;

    my %attrs;
    my %cond;

    _job_find_smart($value, \%cond, \%attrs);

    my $cnt = schema->resultset("Jobs")->search(\%cond, \%attrs)->delete;

    return $cnt;
}

sub job_update_result {
    my %args = @_;

    my $id = int($args{jobid});

    my $r = schema->resultset("Jobs")->search({id => $id})->update(
        {
            result => $args{result},
        });

    return $r;
}

sub _job_find_smart($$$) {
    my ($value, $cond, $attrs) = @_;

    if (ref $value eq '') {
        if ($value =~ /\.iso/) {
            $value = {ISO => $value};
        }
    }
    if (ref $value eq 'HASH') {
        my $i = 0;
        while (my ($k, $v) = each %$value) {
            ++$i;
            my $t = 'settings';
            $t .= '_' . $i if $i > 1;
            $cond->{$t . '.key'}   = $k;
            $cond->{$t . '.value'} = $v;
        }
        while ($i--) {
            push @{$attrs->{join}}, 'settings';
        }
    }
    else {
        # TODO: support by name and by iso here
        $cond->{id} = $value;
    }
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
            colums => [qw/id worker_id/]});

    $jobs->search(
        {
            result => OpenQA::Schema::Result::Jobs::NONE,
        }
      )->update(
        {
            result => OpenQA::Schema::Result::Jobs::PARALLEL_RESTARTED,
        });

    while (my $j = $jobs->next) {
        log_debug("enqueuing abort for " . $j->id . " " . $j->worker_id);
        command_enqueue(workerid => $j->worker_id, command => 'abort', job_id => $j->id);
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
            colums => [qw/id worker_id/],
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
        command_enqueue(workerid => $j->worker_id, command => 'abort', job_id => $j->id);
    }

    return @duplicated;
}

sub job_cancel($;$) {
    my $value = shift or die "missing name parameter\n";
    my $newbuild = shift || 0;

    my %attrs;
    my %cond;

    _job_find_smart($value, \%cond, \%attrs);

    $cond{state} = OpenQA::Schema::Result::Jobs::SCHEDULED;

    # first set all scheduled jobs to cancelled
    my $r = schema->resultset("Jobs")->search(\%cond, \%attrs)->update(
        {
            state  => OpenQA::Schema::Result::Jobs::CANCELLED,
            result => ($newbuild) ? OpenQA::Schema::Result::Jobs::OBSOLETED : OpenQA::Schema::Result::Jobs::USER_CANCELLED
        });

    my $jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);
    while (my $j = $jobs->next) {
        _job_skip_children($j->id);
    }

    $attrs{columns} = [qw/id worker_id/];
    $cond{state}    = [OpenQA::Schema::Result::Jobs::EXECUTION_STATES];
    # then tell workers to cancel their jobs
    $jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);

    $jobs->search(
        {
            result => OpenQA::Schema::Result::Jobs::NONE,
        }
      )->update(
        {
            result => ($newbuild) ? OpenQA::Schema::Result::Jobs::OBSOLETED : OpenQA::Schema::Result::Jobs::USER_CANCELLED,
        });

    while (my $j = $jobs->next) {
        if ($newbuild) {
            log_debug("enqueuing obsolete for " . $j->id . " " . $j->worker_id);
            command_enqueue(workerid => $j->worker_id, command => 'obsolete', job_id => $j->id);
        }
        else {
            log_debug("enqueuing cancel for " . $j->id . " " . $j->worker_id);
            command_enqueue(workerid => $j->worker_id, command => 'cancel', job_id => $j->id);
        }
        _job_skip_children($j->id);
        _job_stop_children($j->id);

        ++$r;
    }
    return $r;
}

sub job_stop {
    carp "job_stop is deprecated, use job_cancel instead";
    return job_cancel(@_);
}

#
# Commands API
#

sub command_enqueue_checked {
    my %args = @_;

    _validate_workerid($args{workerid});

    return command_enqueue(%args);
}

# FIXME: pass worker directly
sub command_enqueue {
    my %args = @_;

    die "invalid command\n" unless exists $worker_commands{$args{command}};
    if (ref $worker_commands{$args{command}} eq 'CODE') {
        my $rs     = schema->resultset("Workers");
        my $worker = $rs->find($args{workerid});
        $worker_commands{$args{command}}->($worker);
    }
    my $msg = $args{command};
    ws_send($args{workerid}, $msg, $args{job_id});
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
        return undef;
    }

    return schema->resultset("Assets")->search(\%cond, \%attrs);
}

sub asset_delete {
    return asset_get(@_)->delete();
}

sub asset_register {
    my %args = @_;

    my $type = $args{type} // '';

    unless ($OpenQA::Schema::Result::Assets::types{$type}) {
        warn "asset type '$type' invalid";
        return undef;
    }
    my $name = $args{name} // '';
    unless ($name && $name =~ /^[0-9A-Za-z+-._]+$/ && -e join('/', $OpenQA::Utils::assetdir, $type, $name)) {
        warn "asset name '$name' invalid or does not exist";
        return undef;
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
