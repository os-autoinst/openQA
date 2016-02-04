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
use File::Spec::Functions qw/catfile/;
use File::Temp qw/tempdir/;
use Mojo::URL;
use Mojo::Util 'url_unescape';
use Try::Tiny;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use OpenQA::Utils qw/log_debug parse_assets_from_settings/;
use db_helpers qw/rndstr/;

use OpenQA::IPC;

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register job_create
  job_get jobs_get_dead_worker
  job_grab job_set_done job_set_waiting job_set_running job_notify_workers
  job_delete job_update_result job_restart job_cancel command_enqueue
  job_set_stop job_stop iso_stop_old_builds
  asset_list asset_get asset_delete asset_register query_jobs
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
    my $ipc = OpenQA::IPC->ipc;
    $ipc->websockets('ws_send_all', 'job_available');
}

=item job_create

create a job

=cut
sub job_create {
    my ($settings, $batch_mode) = @_;
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
    # this will associate currently available assets with job
    $job->register_assets_from_settings;

    unless ($batch_mode) {
        # enqueue gru job
        schema->resultset('GruTasks')->create(
            {
                taskname => 'limit_assets',
                priority => 10,
                args     => [],
                run_at   => now(),
            });

        job_notify_workers();
    }

    return $job;
}

sub job_create_dependencies {
    my ($job, $testsuite_mapping) = @_;

    my $settings = $job->settings_hash;
    for my $depname ('START_AFTER_TEST', 'PARALLEL_WITH') {
        next unless defined $settings->{$depname};
        for my $testsuite (_parse_dep_variable($settings->{$depname}, $settings)) {
            if (!defined $testsuite_mapping->{$testsuite}) {
                warn sprintf('%s=%s not found - check for typos and dependency cycles', $depname, $testsuite);
            }
            else {
                my $dep;
                if ($depname eq 'START_AFTER_TEST') {
                    $dep = OpenQA::Schema::Result::JobDependencies::CHAINED;
                }
                elsif ($depname eq 'PARALLEL_WITH') {
                    $dep = OpenQA::Schema::Result::JobDependencies::PARALLEL;
                }
                else {
                    die 'Unknown dependency type';
                }
                for my $parent (@{$testsuite_mapping->{$testsuite}}) {

                    schema->resultset('JobDependencies')->create(
                        {
                            child_job_id  => $job->id,
                            parent_job_id => $parent,
                            dependency    => $dep,
                        });
                }
            }
        }
    }
}

sub job_get($) {
    my $value = shift;

    return if !defined($value);

    if ($value =~ /^\d+$/) {
        return _job_get({'me.id' => $value});
    }
    return _job_get({slug => $value});
}

sub jobs_get_dead_worker {
    my $threshold = shift;

    my %cond = (
        state              => OpenQA::Schema::Result::Jobs::RUNNING,
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
    return unless $job;
    return $job->to_hash(assets => 1);
}

sub query_jobs {
    my %args = @_;
    # For args where we accept a list of values, allow passing either an
    # array ref or a comma-separated list
    for my $arg (qw/state ids result/) {
        next unless $args{$arg};
        $args{$arg} = [split(',', $args{$arg})] unless (ref($args{$arg}) eq 'ARRAY');
    }

    my @conds;
    my %attrs;
    my @joins;

    unless ($args{idsonly}) {
        push @{$attrs{prefetch}}, 'settings';
        push @{$attrs{prefetch}}, 'parents';
        push @{$attrs{prefetch}}, 'children';
    }

    if ($args{state}) {
        push(@conds, {'me.state' => $args{state}});
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
    # allows explicit filtering, e.g. in query url "...&result=failed&result=incomplete"
    if ($args{result}) {
        push(@conds, {'me.result' => {-in => $args{result}}});
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
        my $subquery = schema->resultset("JobGroups")->search({name => $args{group}})->get_column('id')->as_query;
        push(
            @conds,
            {
                'me.group_id' => {-in => $subquery},
            });
    }

    if ($args{ids}) {
        push(@conds, {'me.id' => {-in => $args{ids}}});
    }
    elsif ($args{match}) {
        # Text search across some settings
        my $subquery = schema->resultset("JobSettings")->search(
            {
                key => ['DISTRI', 'FLAVOR', 'BUILD', 'TEST', 'VERSION'],
                value => {'-like' => "%$args{match}%"},
            });
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }
    else {
        my @js_joins;
        my @js_conds;
        # Search into the following job_settings
        for my $setting (qw(build iso distri version flavor arch)) {
            if ($args{$setting}) {
                # for dynamic self joins we need to be creative ;(
                my $tname = 'me';
                if (@js_conds) {
                    $tname = "siblings";
                    if (@js_joins) {
                        $tname = "siblings_" . (int(@js_joins) + 1);
                    }
                    push(@js_joins, 'siblings');
                }
                push(
                    @js_conds,
                    {
                        "$tname.key"   => uc($setting),
                        "$tname.value" => $args{$setting}});
            }
        }
        my $subquery = schema->resultset("JobSettings")->search({-and => \@js_conds}, {join => \@js_joins});
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
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

        my $worker = schema->resultset("Workers")->find($workerid);

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
                    state     => OpenQA::Schema::Result::Jobs::SCHEDULED,
                    worker_id => 0
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
                state     => OpenQA::Schema::Result::Jobs::SCHEDULED,
                worker_id => 0,
                id        => \@available_cond,
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
    #    $job_hashref = _job_get({'me.id' => $job->id});
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

    $job->release_networks();

    $job->owned_locks->delete;
    $job->locked_locks->update({locked_by => undef});

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

# return settings key for given job settings
sub _settings_key {
    my ($settings) = @_;
    return $settings->{TEST} . ':' . $settings->{MACHINE};

}

# parse dependency variable in format like "suite1,suite2,suite3"
# and return settings key for each entry
# TODO: allow inter-machine dependency
sub _parse_dep_variable {
    my ($value, $settings) = @_;

    return unless defined $value;

    my @after = split(/\s*,\s*/, $value);

    return map { $_ . ':' . $settings->{MACHINE} } @after;
}

# sort the job list so that children are put after parents
sub _sort_dep {
    my ($list) = @_;

    my %done;
    my %count;
    my @out;

    for my $job (@$list) {
        $count{_settings_key($job)} //= 0;
        $count{_settings_key($job)}++;
    }


    my $added;
    do {
        $added = 0;
        for my $job (@$list) {
            next if $done{$job};
            my @after;
            push @after, _parse_dep_variable($job->{START_AFTER_TEST}, $job);
            push @after, _parse_dep_variable($job->{PARALLEL_WITH},    $job);

            my $c = 0;    # number of parens that must go to @out before this job
            foreach my $a (@after) {
                $c += $count{$a} if defined $count{$a};
            }

            if ($c == 0) {    # no parents, we can do this job
                push @out, $job;
                $done{$job} = 1;
                $count{_settings_key($job)}--;
                $added = 1;
            }
        }
    } while ($added);

    #cycles, broken dep, put at the end of the list
    for my $job (@$list) {
        next if $done{$job};
        push @out, $job;
    }

    return \@out;
}

sub _generate_jobs {
    my (%args) = @_;

    my $ret = [];

    my @products = schema->resultset('Products')->search(
        {
            distri  => lc($args{DISTRI}),
            version => $args{VERSION},
            flavor  => $args{FLAVOR},
            arch    => $args{ARCH},
        });

    unless (@products) {
        warn "no products found, retrying version wildcard";
        @products = schema->resultset('Products')->search(
            {
                distri  => lc($args{DISTRI}),
                version => '*',
                flavor  => $args{FLAVOR},
                arch    => $args{ARCH},
            });
    }

    if (!@products) {
        carp "no products found for " . join('-', map { $args{$_} } qw/DISTRI VERSION FLAVOR ARCH/);
    }

    my %wanted;    # jobs specified by $args{TEST} or $args{MACHINE} or their parents

    for my $product (@products) {
        my @templates = $product->job_templates;
        unless (@templates) {
            carp "no templates found for " . join('-', map { $args{$_} } qw/DISTRI VERSION FLAVOR ARCH/);
        }
        for my $job_template (@templates) {
            my %settings = map { $_->key => $_->value } $product->settings;

            # we need to merge worker classes of all 3
            my @classes;
            if (my $class = delete $settings{WORKER_CLASS}) {
                push @classes, $class;
            }

            my %tmp_settings = map { $_->key => $_->value } $job_template->machine->settings;
            if (my $class = delete $tmp_settings{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_settings} = values %tmp_settings;

            %tmp_settings = map { $_->key => $_->value } $job_template->test_suite->settings;
            if (my $class = delete $tmp_settings{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_settings} = values %tmp_settings;
            $settings{TEST}               = $job_template->test_suite->name;
            $settings{MACHINE}            = $job_template->machine->name;
            $settings{BACKEND}            = $job_template->machine->backend;
            $settings{WORKER_CLASS} = join(',', sort(@classes));

            for (keys %args) {
                next if $_ eq 'TEST' || $_ eq 'MACHINE';
                $settings{uc $_} = $args{$_};
            }
            # Makes sure tha the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO}     = $job_template->prio;
            $settings{GROUP_ID} = $job_template->group_id;

            # variable expansion
            # replace %NAME% with $settings{NAME}
            my $expanded;
            do {
                $expanded = 0;
                for my $var (keys %settings) {
                    if ((my $val = $settings{$var}) =~ /(%\w+%)/) {
                        my $replace_var = $1;
                        $replace_var =~ s/^%(\w+)%$/$1/;
                        my $replace_val = $settings{$replace_var};
                        next unless defined $replace_val;
                        $replace_val = '' if $replace_var eq $var;    #stop infinite recursion
                        $val =~ s/%${replace_var}%/$replace_val/g;
                        $settings{$var} = $val;
                        $expanded = 1;
                    }
                }
            } while ($expanded);

            if (   (!$args{TEST} || $args{TEST} eq $settings{TEST})
                && (!$args{MACHINE} || $args{MACHINE} eq $settings{MACHINE}))
            {
                $wanted{_settings_key(\%settings)} = 1;
            }

            push @$ret, \%settings;
        }
    }

    $ret = _sort_dep($ret);
    # the array is sorted parents first - iterate it backward
    for (my $i = $#{$ret}; $i >= 0; $i--) {
        if ($wanted{_settings_key($ret->[$i])}) {
            # add parents to wanted list
            my @parents;
            push @parents, _parse_dep_variable($ret->[$i]->{START_AFTER_TEST}, $ret->[$i]);
            push @parents, _parse_dep_variable($ret->[$i]->{PARALLEL_WITH},    $ret->[$i]);
            for my $p (@parents) {
                $wanted{$p} = 1;
            }
        }
        else {
            splice @$ret, $i, 1;    # not wanted - delete
        }
    }
    return $ret;
}

sub job_schedule_iso {
    my (%args) = @_;
    # register assets posted here right away, in case no job
    # templates produce jobs.
    for my $a (values %{parse_assets_from_settings(\%args)}) {
        asset_register(%$a);
    }
    my $noobsolete = delete $args{_NOOBSOLETEBUILD};
    # ISOURL == ISO download. If the ISO already exists, skip the
    # download step (below) entirely by leaving $isodlpath unset.
    my $isodlpath;
    if ($args{ISOURL}) {
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST ISOs
        $args{ISOURL} = url_unescape($args{ISOURL});
        # set $args{ISO} to the URL filename if we only got ISOURL.
        # This has to happen *before* _generate_jobs so the jobs have
        # ISO set
        if (!$args{ISO}) {
            $args{ISO} = Mojo::URL->new($args{ISOURL})->path->parts->[-1];
        }
        # full path to download target location
        my $fulliso = catfile($OpenQA::Utils::isodir, $args{ISO});
        unless (-s $fulliso) {
            $isodlpath = $fulliso;
        }
    }
    my $jobs = _generate_jobs(%args);

    # XXX: take some attributes from the first job to guess what old jobs to
    # cancel. We should have distri object that decides which attributes are
    # relevant here.
    if (!$noobsolete && $jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my %cond;
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            job_cancel(\%cond, 1);    # have new build jobs instead
        }
    }

    # the jobs are now sorted parents first

    my @ids     = ();
    my $coderef = sub {
        my @jobs = ();
        # remember ids of created parents
        my %testsuite_ids;            # key: "suite:machine", value: array of job ids

        for my $settings (@{$jobs || []}) {
            my $prio     = delete $settings->{PRIO};
            my $group_id = delete $settings->{GROUP_ID};

            # create a new job with these parameters and count if successful, do not send job notifies yet
            my $job = job_create($settings, 1);

            if ($job) {
                push @jobs, $job;

                $testsuite_ids{_settings_key($settings)} //= [];
                push @{$testsuite_ids{_settings_key($settings)}}, $job->id;

                # change prio only if other than default prio
                if (defined($prio) && $prio != 50) {
                    $job->priority($prio);
                }
                $job->group_id($group_id);
                $job->update;
            }
        }

        # jobs are created, now recreate dependencies and extract ids
        for my $job (@jobs) {
            job_create_dependencies($job, \%testsuite_ids);
            push @ids, $job->id;
        }
    };

    try {
        schema->txn_do($coderef);
    }
    catch {
        my $error = shift;
        OpenQA::Utils::log_debug("rollback job_schedule_iso: $error");
        die "Rollback failed during failed job_schedule_iso: $error"
          if ($error =~ /Rollback failed/);
        @ids = ();
    };

    # enqueue gru jobs
    if ($isodlpath and @ids) {
        # array of hashrefs job_id => id; this is what create needs
        # to create entries in a related table (gru_dependencies)
        my @jobsarray = map +{job_id => $_}, @ids;
        schema->resultset('GruTasks')->create(
            {
                taskname => 'download_iso',
                priority => 20,
                args     => [$args{ISOURL}, $isodlpath],
                run_at   => now(),
                jobs     => \@jobsarray,
            });
    }
    schema->resultset('GruTasks')->create(
        {
            taskname => 'limit_assets',
            priority => 10,
            args     => [],
            run_at   => now(),
        });

    #notify workers new jobs are available
    job_notify_workers;
    return @ids;
}

#
# Commands API
#
sub command_enqueue {
    my %args = @_;
    unless (defined $args{command} && defined $args{workerid}) {
        carp 'missing mandatory options';
        return;
    }

    unless (exists $worker_commands{$args{command}}) {
        carp 'invalid command "' . $args{command} . "\"\n";
        return;
    }
    if (ref $worker_commands{$args{command}} eq 'CODE') {
        my $rs     = schema->resultset("Workers");
        my $worker = $rs->find($args{workerid});
        unless ($worker) {
            carp 'invalid workerid "' . $args{workerid} . "\"\n";
            return;
        }
        $worker_commands{$args{command}}->($worker);
    }
    my $msg = $args{command};
    my $res;
    try {
        my $ipc = OpenQA::IPC->ipc;
        $res = $ipc->websockets('ws_send', $args{workerid}, $msg, $args{job_id});
    };
    return $res;
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
