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
use Data::Dump qw/pp/;
use Date::Format qw/time2str/;
use DateTime;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use openqa ();

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
);


our %worker_commands = map { $_ => 1 } qw/
  quit
  abort
  cancel
  stop_waitforneedle
  reload_needles_and_retry
  enable_interactive_mode
  disable_interactive_mode
  continue_waitforneedle
  /;


sub schema{
    CORE::state $schema;
    $schema = openqa::connect_db() unless $schema;
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

    for my $i (qw/DISTRI VERSION ISO DESKTOP TEST/) {
        die "need one $i key\n" unless exists $settings{$i};
    }

    for my $i (qw/ISO NAME/) {
        next unless $settings{$i};
        die "invalid character in $i\n" if $settings{$i} =~ /\//; # TODO: use whitelist?
    }

    unless (-e sprintf("%s/%s", $openqa::isodir, $settings{ISO})) {
        die "ISO does not exist\n";
    }

    my @settings = ();
    while(my ($k, $v) = each %settings) {
        push @settings, { key => $k, value => $v };
    }

    my %new_job_args = (
        settings => \@settings,
        test => $settings{'TEST'},
    );

    if ($settings{NAME}) {
        my $njobs = schema->resultset("Jobs")->search({ slug => $settings{'NAME'} })->count;
        return 0 if $njobs;

        $new_job_args{slug} = $settings{'NAME'};
    }

    my $job = schema->resultset("Jobs")->create(\%new_job_args);

    return $job->id;
}

sub job_get($) {
    my $value = shift;

    return undef if !defined($value);

    if ($value =~ /^\d+$/) {
        return _job_get({ id => $value });
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

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;

    my $job = schema->resultset("Jobs")->search($search)->first;
    my $job_hashref;
    if ($job) {
        $job_hashref = _hashref($job, qw/ id name priority result worker_id clone_id t_started t_finished test test_branch/);
        # XXX: use +columns in query above?
        $job_hashref->{state} = $job->state->name;
        $job_hashref->{result} = $job->result->name;
        _job_fill_settings($job_hashref);
    }
    return $job_hashref;
}

sub _job_fill_settings {
    my $job = shift;
    my $job_settings = schema->resultset("JobSettings")->search({ job_id => $job->{id} });
    $job->{settings} = {};
    while(my $js = $job_settings->next) {
        $job->{settings}->{$js->key} = $js->value;
    }

    if ($job->{name} && !$job->{settings}->{NAME}) {
        $job->{settings}->{NAME} = sprintf "%08d-%s", $job->{id}, $job->{name};
    }

    return $job;
}

sub list_jobs {
    my %args = @_;

    my %cond = ();
    my %attrs = ();

    if ($args{state}) {
        my $states_rs = schema->resultset("JobStates")->search({ name => [split(',', $args{state})] });
        $cond{state_id} = {-in => $states_rs->get_column("id")->as_query};
    }
    if ($args{maxage}) {
        my $agecond = { '>' => time2str('%Y-%m-%d %H:%M:%S', time - $args{maxage}, 'UTC') };
        $cond{'-or'} = [
            'me.t_created' => $agecond,
            'me.t_started' => $agecond,
            'me.t_finished' => $agecond
        ];
    }
    if ($args{ignore_incomplete}) {
        my $results_rs = schema->resultset("JobResults")->search({ name => 'incomplete' });
        $cond{result_id} = { '!=' => $results_rs->get_column("id")->as_query };
    }
    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page}||0;

    if ($args{build}) {
        $cond{'settings.key'} = "BUILD";
        $cond{'settings.value'} = $args{build};
        $attrs{join} = 'settings';
    }
    if ($args{iso}) {
        $cond{'settings.key'} = "ISO";
        $cond{'settings.value'} = $args{iso};
        $attrs{join} = 'settings';
    }
    if ($args{match}) {
        $cond{'settings.key'} = ['DISTRI', 'FLAVOR', 'BUILD', 'TEST'];
        $cond{'settings.value'} = { '-like' => "%$args{match}%" };
        $attrs{join} = 'settings';
        $attrs{group_by} = ['me.id'];
    }
    $attrs{order_by} = ['me.id DESC'];

    my $jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);

    my @results = ();
    while( my $job = $jobs->next) {
        my $j = _hashref($job, qw/ id name priority worker_id clone_id t_started t_finished test test_branch/);
        $j->{state} = $job->state->name;
        $j->{result} = $job->result->name;
        $j->{machine} = $job->machine;
        _job_fill_settings($j) if $args{fulldetails};
        push @results, $j;
    }

    return \@results;
}

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab {
    my %args = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my $result;
    while (1) {
        my $now = "datetime('now')";
        $result = schema->resultset("Jobs")->search(
            {
                state_id => schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
                worker_id => 0,
            },
            { order_by => { -asc => 'priority'}, rows => 1}
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
    $job_hashref = _job_get(
        {
            id => schema->resultset("Jobs")->search(
                {
                    state_id => schema->resultset("JobStates")->search({ name => "running" })->single->id,
                    worker_id => $workerid,
                }
            )->single->id,
        }
    ) if $result != 0;

    return $job_hashref;
}

=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters
sub job_set_done {
    my %args = @_;
    my $jobid = int($args{jobid});
    my $result = schema->resultset("JobResults")->search({ name => $args{result}})->single;

    die "invalid result string" unless $result;

    my $now = "datetime('now')";
    my $r = schema->resultset("Jobs")->search({ id => $jobid })->update(
        {
            state_id => schema->resultset("JobStates")->search({ name => "done" })->single->id,
            worker_id => 0,
            t_finished => \$now,
            result_id => $result->id,
        }
    );
    return $r;
}

=item job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    # TODO: only allowed for running jobs
    my $r = schema->resultset("Jobs")->search({ id => $jobid })->update(
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
            state_id => { -in => $states_rs->get_column("id")->as_query },
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

    print STDERR "duplicating $args{jobid}\n" if $debug;

    my $job = schema->resultset("Jobs")->find({id => $args{jobid}});
    return undef unless $job;

    my $clone = $job->duplicate(\%args);
    if (defined($clone)) {
        print STDERR "new job ".$clone->id."\n" if $debug;
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

sub job_cancel {
    my $value = shift or die "missing name parameter\n";

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

    $attrs{colums} = [qw/id worker_id/];
    $cond{state_id} = {-in => schema->resultset("JobStates")->search({ name => [qw/running waiting/] })->get_column("id")->as_query};
    # then tell workers to cancel their jobs
    my $jobs = schema->resultset("Jobs")->search(\%cond, \%attrs);
    while (my $j = $jobs->next) {
        print STDERR "enqueuing cancel for ".$j->id." ".$j->worker_id."\n" if $debug;
        command_enqueue(workerid => $j->worker_id, command => 'cancel');
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

1;
# vim: set sw=4 et:
