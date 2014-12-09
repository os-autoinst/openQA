# Copyright (C) 2013,2014 SUSE Linux Products GmbH
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

package Scheduler;

use strict;
use warnings;
use diagnostics;

use DBIx::Class::ResultClass::HashRefInflator;
use Digest::MD5;
use Data::Dump qw/dd pp/;
use Date::Format qw/time2str/;
use DateTime;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use openqa ();

use OpenQA::Variables;

use Carp;

our $debug;
BEGIN {
    $debug = $ENV{HARNESS_IS_VERBOSE};
}

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register worker_get workers_get_dead_worker list_workers job_create
  job_get job_get_by_workerid jobs_get_dead_worker list_jobs job_grab job_set_done
  job_set_waiting job_set_running job_set_prio
  job_delete job_update_result job_restart job_cancel command_enqueue
  command_get list_commands command_dequeue iso_cancel_old_builds
  job_set_stop job_stop iso_stop_old_builds
  job_get_assets
  asset_list asset_get asset_delete asset_register
);


our %worker_commands = map { $_ => 1 } qw/
  quit
  abort
  cancel
  obsolete
  stop_waitforneedle
  reload_needles_and_retry
  enable_interactive_mode
  disable_interactive_mode
  continue_waitforneedle
  /;

# job states, initialized in schema()
# name => id
our %job_states;

sub schema{
    CORE::state $schema;
    return $schema if $schema;

    $schema = openqa::connect_db();
    if ($schema) {
        my $rs = $schema->resultset("JobStates")->search(undef, { columns => [qw/id name/], });
        %job_states = map { $_->name => $_->id } $rs->all() if $rs;
        die "database schema not initialized properly!\n" unless keys %job_states == 6;
    }

    return $schema;
}

=item _hashref()

Convert an ORM object into a hashref. The API only export hashes and
not ORM objects.

=cut

# XXX TODO - Remove this useless function when is not needed anymore
sub _hashref {
    my $obj = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
        $hashref{$field} = $obj->$field;
    }

    return \%hashref;
}


#
# Workers API
#

# param hash: host, instance, backend
sub worker_register {
    my ($host, $instance, $backend) = @_;

    my $worker = schema->resultset("Workers")->search(
        {
            host => $host,
            instance => int($instance),
        }
    )->first;

    if ($worker) { # worker already known. Update fields and return id
        $worker->update({ t_updated => 0 });
    }
    else {
        $worker = schema->resultset("Workers")->create(
            {
                host => $host,
                instance => $instance,
                backend => $backend,
            }
        );
    }

    # in case the worker died ...
    # ... restart jobs assigned to this worker
    for my $j ($worker->jobs->all()) {
        job_duplicate(jobid => $j->id);
    }
    # .. set them to incomplete
    $worker->jobs->update_all(
        {
            state_id => schema->resultset("JobStates")->search({ name => "done" })->single->id,
            result_id => schema->resultset("JobResults")->search({ name => 'incomplete' })->single->id,
            worker_id => 0,
        }
    );
    # ... delete pending commands
    schema->resultset("Commands")->search(
        {
            worker_id => $worker->id
        }
    )->delete_all();

    die "got invalid id" unless $worker->id;
    return $worker->id;
}

# param hash:
# XXX TODO: Remove HashRefInflator
sub worker_get {
    my $workerid = shift;

    my $rs = schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my $worker = $rs->find($workerid);

    # TODO: transfer these from the worker
    my $WORKER_PORT_START = 20003;

    $worker->{properties}->{WORKER_VNC_PORT} = $worker->{'instance'} + 90;
    $worker->{properties}->{WORKER_PORT} = $worker->{'instance'} * 10 + $WORKER_PORT_START;

    for my $r (schema->resultset("WorkerProperties")->search({ worker_id => $worker->{id} })) {
        $worker->{properties}->{$r->key} = $r->value;
    }

    return $worker;
}

sub workers_get_dead_worker {
    my $dt = DateTime->now(time_zone=>'UTC');
    # set the threshold as 00 second
    $dt->set_second(00);
    my $threshold = join ' ',$dt->ymd, $dt->hms;

    my %cond = (
        'host' => { '!=' => 'NONE'},
        't_updated' => { '<' => $threshold},
    );

    my $dead_workers = schema->resultset("Workers")->search(\%cond);

    my @results = ();
    while( my $worker = $dead_workers->next) {
        my $j = _hashref($worker, qw/ id host instance backend/);
        push @results, $j;
    }

    return \@results;
}

# XXX TODO: Remove HashRefInflator
sub list_workers {
    my $rs = schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @workers = $rs->all;

    return \@workers;
}

sub _validate_workerid($) {
    my $workerid = shift;
    die "invalid worker id\n" unless $workerid;
    my $rs = schema->resultset("Workers")->search({ id => $workerid });
    die "invalid worker id $workerid\n" unless $rs->count;
}

sub _seen_worker($) {
    my $id = shift;
    schema->resultset("Workers")->find($id)->update({ t_updated => 0 });
}


#
# Jobs API
#

=item job_create

create a job

=cut
sub job_create {
    my %settings = @_;

    if (my $error = OpenQA::Variables->new()->check(%settings)) {
        die "$error\n";
    }

    my @assets;
    for my $k (keys %settings) {
        if ($k eq 'ISO') {
            push @assets, { type => 'iso', name => $settings{$k}};
        }
        if ($k =~ /^HDD_\d$/) {
            push @assets, { type => 'hdd', name => $settings{$k}};
        }
        if ($k =~ /^REPO_\d$/) {
            push @assets, { type => 'repo', name => $settings{$k}};
        }
    }

    die "job has no assets\n" unless @assets;

    for my $a (@assets) {
        die "invalid character in $a->{name}\n" if $a->{name} =~ /\//; # TODO: use whitelist?

        unless (-e sprintf("%s/%s", $openqa::assetdir, $a->{type}, $a->{name})) {
            die "$a->{name} does not exist\n";
        }
    }

    my %new_job_args = (test => $settings{'TEST'},);

    if ($settings{NAME}) {
        my $njobs = schema->resultset("Jobs")->search({ slug => $settings{'NAME'} })->count;
        return 0 if $njobs;

        $new_job_args{slug} = $settings{'NAME'};
        delete $settings{NAME};
    }

    if ($settings{_START_AFTER_JOBS}) {
        for my $id (@{$settings{_START_AFTER_JOBS}}) {
            push @{$new_job_args{parents}},
              {
                parent_job_id => $id,
                dep_id => schema->resultset("Dependencies")->search({ name => "chained" })->single->id,
              };
        }
        delete $settings{_START_AFTER_JOBS};
    }


    while(my ($k, $v) = each %settings) {
        push @{$new_job_args{settings}}, { key => $k, value => $v };
    }

    for my $a (@assets) {
        push @{$new_job_args{jobs_assets}}, { asset => $a };
    }

    my $job = schema->resultset("Jobs")->create(\%new_job_args);
    return $job->id;
}

sub job_get($) {
    my $value = shift;

    return undef if !defined($value);

    if ($value =~ /^\d+$/) {
        return _job_get({ 'me.id' => $value });
    }
    return _job_get({slug => $value });
}

sub job_get_by_workerid($) {
    my $workerid = shift;

    return undef if !defined($workerid);

    return _job_get({worker_id => $workerid });
}

sub jobs_get_dead_worker {
    my $threshold = shift;

    my %cond = (
        'state_id' => 1,
        'worker.t_updated' => { '<' => $threshold},
    );
    my %attrs = (join => 'worker',);

    my $dead_jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);

    my @results = ();
    while( my $job = $dead_jobs->next) {
        my $j = _hashref($job, qw/ id state_id result_id worker_id/);
        push @results, $j;
    }

    return \@results;
}

sub _job_to_hash {
    my ($job, %args) = @_;
    return undef unless $job;
    my $j = _hashref($job, qw/ id name priority worker_id clone_id retry_avbl t_started t_finished test test_branch/);
    $j->{state} = $job->state->name;
    $j->{result} = $job->result->name;
    $j->{settings} = { map { $_->key => $_->value } $job->settings->all() };
    if ($job->name && !$j->{settings}->{NAME}) {
        $j->{settings}->{NAME} = sprintf "%08d-%s", $job->id, $job->name;
    }
    if ($args{assets}) {
        for my $a ($job->jobs_assets->all()) {
            push @{$j->{assets}->{$a->asset->type}}, $a->asset->name;
        }
    }
    $j->{parents} = [];
    for my $p ($job->parents->all()) {
        push @{$j->{parents}}, $p->parent_job_id;
    }
    return $j;
}

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;
    my %attrs = ();

    push @{$attrs{'prefetch'}}, qw/state result/;
    push @{$attrs{'prefetch'}}, 'settings';

    my $job = schema->resultset("Jobs")->search($search, \%attrs)->first;
    return _job_to_hash($job, assets => 1);
}

sub job_get_assets {
    my $id = shift;
    my $ret = [];

    my $rc = schema->resultset("Jobs")->find({id => $id})->assets();
    while (my $a = $rc->next()) {
        push @$ret, { id => $a->id, type => $a->type, name => $a->name };
    }

    return $ret;
}

sub list_jobs {
    my %args = @_;

    my @conds;
    my %attrs;
    my @joins;

    push @{$attrs{'prefetch'}}, qw/state result/;
    push @{$attrs{'prefetch'}}, 'settings';
    push @{$attrs{'prefetch'}}, {'jobs_assets' => 'asset' };

    if ($args{state}) {
        my $states_rs = schema->resultset("JobStates")->search({ name => [split(',', $args{state})] });
        push(@conds, { 'me.state_id' => {-in => $states_rs->get_column("id")->as_query}});
    }
    if ($args{maxage}) {
        my $agecond = { '>' => time2str('%Y-%m-%d %H:%M:%S', time - $args{maxage}, 'UTC') };
        push(
            @conds,
            {
                -or => [
                    'me.t_created' => $agecond,
                    'me.t_started' => $agecond,
                    'me.t_finished' => $agecond
                ]
            }
        );
    }
    if ($args{ignore_incomplete}) {
        my $results_rs = schema->resultset("JobResults")->search({ name => 'incomplete' });
        push(@conds, {'me.result_id' => { '!=' => $results_rs->get_column("id")->as_query }});
    }
    my $scope = $args{scope} || '';
    if ($scope eq 'relevant') {
        my $states_rs = schema->resultset("JobStates")->search({ name => ['running', 'scheduled'] });
        push(@joins, 'clone');
        push(
            @conds,
            {
                -or => [
                    'me.clone_id' => undef,
                    'clone.state_id' => {-in => $states_rs->get_column("id")->as_query}
                ]
            }
        );
    }
    if ($scope eq 'current') {
        push(@conds, {'me.clone_id' => undef});
    }
    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page}||0;
    if ($args{assetid}) {
        push(@joins, 'jobs_assets');
        push(
            @conds,
            {
                'jobs_assets.asset_id' => $args{assetid},
            }
        );
    }

    # Search into the following job_settings
    for my $setting (qw(build iso distri version flavor)) {
        if ($args{$setting}) {
            my $subquery = schema->resultset("JobSettings")->search(
                {
                    key => uc($setting),
                    value => $args{$setting}
                }
            );
            push(@conds, { 'me.id' => { -in => $subquery->get_column('job_id')->as_query }});
        }
    }
    # Text search across some settings
    if ($args{match}) {
        my $subquery = schema->resultset("JobSettings")->search(
            {
                'key' => ['DISTRI', 'FLAVOR', 'BUILD', 'TEST', 'VERSION'],
                'value' => { '-like' => "%$args{match}%" },
            }
        );
        push(@conds, { 'me.id' => { -in => $subquery->get_column('job_id')->as_query }});
    }
    $attrs{order_by} = ['me.id DESC'];

    $attrs{join} = \@joins if @joins;
    my $jobs = schema->resultset("Jobs")->search({-and => \@conds}, \%attrs);

    my @results = ();
    while( my $job = $jobs->next) {
        push @results, _job_to_hash($job, assets => 1);
    }

    return \@results;
}

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab {
    my %args = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);
    my $workerip = $args{workerip};

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my $result;
    while (1) {
        my $now = "datetime('now')";

        my $blocked = schema->resultset("JobDependencies")->search(
            {
                dep_id => schema->resultset("Dependencies")->search({ name => "chained" })->single->id,
                -or => {
                    state_id => { '!=', schema->resultset("JobStates")->search({ name => "done" })->single->id },
                    result_id => { '!=',  schema->resultset("JobResults")->search({ name => "passed" })->single->id },
                },
            },
            {
                join => 'parent',
            }
        );

        $result = schema->resultset("Jobs")->search(
            {
                state_id => schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
                worker_id => 0,
                id => { -not_in => $blocked->get_column('child_job_id')->as_query},
            },
            { order_by => { -asc => [qw/priority id/] }, rows => 1 }
          )->update(
            {
                state_id => schema->resultset("JobStates")->search({ name => "running" })->single->id,
                worker_id => $workerid,
                t_started => \$now,
            }
          );

        last if $result != 0;
        last unless $blocking;
        # XXX: do something smarter here
        #print STDERR "no jobs for me, sleeping\n";
        #sleep 1;
        last;
    }

    my $job_hashref;
    if ($result != 0) {
        $job_hashref = _job_get(
            {
                'me.id' => schema->resultset("Jobs")->search(
                    {
                        state_id => schema->resultset("JobStates")->search({ name => "running" })->single->id,
                        worker_id => $workerid,
                    }
                )->single->id,
            }
        );
        # store a new one time password both in the job and in the worker properties
        worker_set_property($workerid, 'CONNECT_PASSWORD', _job_set_connect_password($job_hashref));
        worker_set_property($workerid, 'WORKER_IP', $workerip) if $workerip;
    }
    return $job_hashref;
}

sub _job_set_connect_password($) {

    my ($jobref) = @_;
    my @chars = ("A".."Z", "a".."z", '0'..'9');
    my $password;
    $password .= $chars[rand @chars] for 1..32;

    # set a connect password
    my $r = schema->resultset("JobSettings")->find_or_new(
        {
            job_id => $jobref->{id},
            key => 'CONNECT_PASSWORD'
        },
    );
    if (!$r->in_storage) {
        $r->value($password);
        $r->insert;
    }
    else {
        $r->update({ value => $password });
    }

    $jobref->{'settings'}->{'CONNECT_PASSWORD'} = $password;
    return $password;
}

sub worker_set_property($$$) {

    my ($workerid, $key, $val) = @_;

    my $r = schema->resultset("WorkerProperties")->find_or_new(
        {
            worker_id => $workerid,
            key => $key
        }
    );

    if (!$r->in_storage) {
        $r->value($val);
        $r->insert;
    }
    else {
        $r->update({ value => $val });
    }
}

# parent job failed, handle children - set them to done incomplete immediately
sub _job_skip_children{
    my $jobid = shift;

    my $children = schema->resultset("JobDependencies")->search(
        {
            dep_id => schema->resultset("Dependencies")->search({ name => "chained" })->single->id,
            parent_job_id => $jobid,
        },
    );

    my $now = "datetime('now')";

    my $result = schema->resultset("Jobs")->search(
        {
            id => { -in => $children->get_column('child_job_id')->as_query},
        },
      )->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => "done" })->single->id,
            result_id => schema->resultset("JobResults")->search({ name => "incomplete" })->single->id,
            t_started => \$now,
            t_finished => \$now,
        }
      );

    while (my $j = $children->next) {
        my $id = $j->child_job_id;
        _job_skip_children($id);
    }
}

# parent job has been cloned, move the scheduled children to the new one
sub _job_update_parent{
    my $jobid = shift;
    my $new_jobid = shift;

    my $children = schema->resultset("JobDependencies")->search(
        {
            dep_id => schema->resultset("Dependencies")->search({ name => "chained" })->single->id,
            parent_job_id => $jobid,
            state_id => schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
        },
        {
            join => 'child',
        }
    );

    my $result = schema->resultset("JobDependencies")->search(
        {
            dep_id => schema->resultset("Dependencies")->search({ name => "chained" })->single->id,
            parent_job_id => $jobid,
            child_job_id => { -in => $children->get_column('child_job_id')->as_query},
        }
      )->update(
        {
            parent_job_id => $new_jobid,
        }
      );
}



=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters
sub job_set_done {
    my %args = @_;
    my $jobid = int($args{jobid});
    my $newbuild = 0;
    $newbuild = int($args{newbuild}) if defined $args{newbuild};
    my $result = schema->resultset("JobResults")->search({ name => $args{result}})->single;

    die "invalid result string" unless $result;

    my $now = "datetime('now')";
    my $r;
    if ($newbuild) {
        $r = schema->resultset("Jobs")->search({ id => $jobid })->update(
            {
                state_id => schema->resultset("JobStates")->search({ name => "obsoleted" })->single->id,
                worker_id => 0,
                t_finished => \$now,
                result_id => $result->id,
            }
        );
    }
    else {
        $r = schema->resultset("Jobs")->search({ id => $jobid })->update(
            {
                state_id => schema->resultset("JobStates")->search({ name => "done" })->single->id,
                worker_id => 0,
                t_finished => \$now,
                result_id => $result->id,
            }
        );
    }
    if ($args{result} ne 'passed') {
        _job_skip_children($jobid);
    }
    return $r;
}

=item job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    # TODO: only allowed for running jobs
    my $state = schema->resultset("JobStates")->find({name => 'running'})->id;
    my $r = schema->resultset("Jobs")->search(
        {
            id => $jobid,
            state_id => $state
        }
      )->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => "waiting" })->single->id,
        }
      );
    return $r;
}

=item job_set_running

mark job as running. No error check. Meant to be called from worker!

=cut
sub job_set_running {
    my $jobid = shift;

    my $states_rs = schema->resultset("JobStates")->search({ name => ['cancelled', 'waiting'] });
    my $r = schema->resultset("Jobs")->search(
        {
            id => $jobid,
            state_id => { -in => $states_rs->get_column("id")->as_query }
        }
      )->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => "running" })->single->id,
        }
      );
    return $r;
}

sub job_set_prio {
    my %args = @_;

    my $r = schema->resultset("Jobs")->search({ id => $args{jobid} })->update(
        {
            priority => $args{prio},
        }
    );
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
    my $result = schema->resultset("JobResults")->search({ name => $args{result}})->single;

    my $r = schema->resultset("Jobs")->search({ id => $id })->update(
        {
            result_id => $result->id
        }
    );

    return $r;
}

sub _job_find_smart($$$) {
    my ($value, $cond, $attrs) = @_;

    if (ref $value eq '') {
        if ($value =~ /\.iso/) {
            $value = { ISO => $value };
        }
    }
    if (ref $value eq 'HASH') {
        my $i = 0;
        while (my ($k, $v) = each %$value) {
            ++$i;
            my $t = 'settings';
            $t .= '_'.$i if $i > 1;
            $cond->{$t.'.key'} = $k;
            $cond->{$t.'.value'} = $v;
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

sub job_duplicate {
    my %args = @_;
    # set this clone was triggered by manually if it's not auto-clone
    $args{dup_type_auto} = 0 unless defined $args{dup_type_auto};

    print STDERR "duplicating $args{jobid}\n" if $debug;

    my $job = schema->resultset("Jobs")->find({id => $args{jobid}});
    return undef unless $job;

    if($args{dup_type_auto}) {
        if ( int($job->retry_avbl) > 0) {
            $args{retry_avbl} = int($job->retry_avbl)-1;
        }
        else {
            print STDERR "Could not auto-duplicated! The job are auto-duplicated too many times.\nPlease restart the job manually.\n" if $debug;
            return undef;
        }
    }
    else {
        if ( int($job->retry_avbl) > 0) {
            $args{retry_avbl} = int($job->retry_avbl);
        }
        else {
            $args{retry_avbl} = 1; # set retry_avbl back to 1
        }
    }

    my $clone = $job->duplicate(\%args);
    if (defined($clone)) {
        print STDERR "new job ".$clone->id."\n" if $debug;

        _job_update_parent($job->id, $clone->id);

        return $clone->id;
    }
    else {
        print STDERR "clone failed\n" if $debug;
        return undef;
    }
}

sub job_restart {
    my $name = shift or die "missing name parameter\n";

    # TODO: support by name and by iso here
    my $idqry = $name;

    # first, duplicate all jobs that are either running, waiting or done
    my $jobs = schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => schema->resultset("JobStates")->search({ name => [qw/running waiting done/] })->get_column("id")->as_query
            }
        },
        {
            columns => [qw/id/]
        }
    );
    my @duplicated;
    while (my $j = $jobs->next) {
        my $id = job_duplicate(jobid => $j->id);
        push @duplicated, $id if $id;
    }

    # then tell workers to abort
    $jobs = schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => schema->resultset("JobStates")->search({ name => [qw/running waiting/] })->get_column("id")->as_query
            }
        },
        {
            colums => [qw/id worker_id/]
        }
    );
    while (my $j = $jobs->next) {
        print STDERR "enqueuing abort for ".$j->id." ".$j->worker_id."\n" if $debug;
        command_enqueue(workerid => $j->worker_id, command => 'abort');
    }

    # now set all cancelled jobs to scheduled again
    schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => schema->resultset("JobStates")->search({ name => [qw/cancelled/] })->get_column("id")->as_query
            }
        },
        {}
      )->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => 'scheduled' })->single->id
        }
      );
    return @duplicated;
}

sub job_cancel($;$) {
    my $value = shift or die "missing name parameter\n";
    my $newbuild = shift || 0;

    my %attrs;
    my %cond;

    _job_find_smart($value, \%cond, \%attrs);

    $cond{state_id} = {-in => schema->resultset("JobStates")->search({ name => [qw/scheduled/] })->get_column("id")->as_query};

    # first set all scheduled jobs to cancelled
    my $r = schema->resultset("Jobs")->search(\%cond, \%attrs)->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => 'cancelled' })->single->id
        }
    );

    $attrs{columns} = [qw/id worker_id/];
    $cond{state_id} = {-in => schema->resultset("JobStates")->search({ name => [qw/running waiting/] })->get_column("id")->as_query};
    # then tell workers to cancel their jobs
    my $jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);
    while (my $j = $jobs->next) {
        if ($newbuild) {
            print STDERR "enqueuing obsolete for ".$j->id." ".$j->worker_id."\n" if $debug;
            command_enqueue(workerid => $j->worker_id, command => 'obsolete');
        }
        else {
            print STDERR "enqueuing cancel for ".$j->id." ".$j->worker_id."\n" if $debug;
            command_enqueue(workerid => $j->worker_id, command => 'cancel');
        }
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

sub command_enqueue {
    my %args = @_;

    die "invalid command\n" unless $worker_commands{$args{command}};

    my $command = schema->resultset("Commands")->create(
        {
            worker_id => $args{workerid},
            command => $args{command},
        }
    );
    return $command->id;
}

sub command_get {
    my $workerid = shift;

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my @commands = schema->resultset("Commands")->search({ worker_id => $workerid });

    my @as_array = ();
    foreach my $command (@commands) {
        push @as_array, [$command->id, $command->command];
    }

    return \@as_array;
}

sub list_commands {
    my $rs = schema->resultset("Commands");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @commands = $rs->all;

    return \@commands;
}

sub command_dequeue {
    my %args = @_;

    die "missing workerid parameter\n" unless $args{workerid};
    die "missing id parameter\n" unless $args{id};

    _validate_workerid($args{workerid});

    my $r = schema->resultset("Commands")->search(
        {
            id => $args{id},
            worker_id =>$args{workerid},
        }
    )->delete;

    return $r;
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
    $attrs{page} = $args{page}||0;

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

    my $type = $args{type}//'';

    unless ($Schema::Result::Assets::types{$type}) {
        warn "asset type '$type' invalid";
        return undef;
    }
    my $name = $args{name}//'';
    unless ($name && $name =~ /^[0-9A-Za-z+-._]+$/ && -e join('/', $openqa::assetdir, $type, $name)) {
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
        }
    );
    return $asset;
}

1;
# vim: set sw=4 et:
