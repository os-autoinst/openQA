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

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use openqa ();

use Carp;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register worker_get list_workers job_create
    job_get list_jobs job_grab job_set_scheduled job_set_done
    job_set_cancel job_set_waiting job_set_running job_set_prio
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


my $schema = openqa::connect_db();

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

    my $worker = $schema->resultset("Workers")->search({
	host => $host,
	instance => int($instance),
    })->first;

    if ($worker) { # worker already known. Update fields and return id
	$worker->update({ t_updated => 0 });
    } else {
	$worker = $schema->resultset("Workers")->create({
	    host => $host,
	    instance => $instance,
	    backend => $backend,
	});
    }

    # in case the worker died ...
    # ... restart jobs assigned to this worker
    for my $j ($worker->jobs->all()) {
        job_duplicate(jobid => $j->id);
    }
    # .. set them to incomplete
    $worker->jobs->update_all({
       state_id => $schema->resultset("JobStates")->search({ name => "done" })->single->id,
       result_id => $schema->resultset("JobResults")->search({ name => 'incomplete' })->single->id,
       worker_id => 0,
    });
    # ... delete pending commands
    $schema->resultset("Commands")->search({
	worker_id => $worker->id
    })->delete_all();

    die "got invalid id" unless $worker->id;
    return $worker->id;
}

# param hash:
# XXX TODO: Remove HashRedInflator
sub worker_get {
    my $workerid = shift;

    my $rs = $schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my $worker = $rs->find($workerid);

    return $worker;
}

# XXX TODO: Remove HashRedInflator
sub list_workers {
    my $rs = $schema->resultset("Workers");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @workers = $rs->all;

    return \@workers;
}

sub _validate_workerid($) {
    my $workerid = shift;
    die "invalid worker id\n" unless $workerid;
    my $rs = $schema->resultset("Workers")->search({ id => $workerid });
    die "invalid worker id $workerid\n" unless $rs->count;
}

sub _seen_worker($) {
    my $id = shift;
    $schema->resultset("Workers")->find($id)->update({ t_updated => 0 });
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
	    my $njobs = $schema->resultset("Jobs")->search({ slug => $settings{'NAME'} })->count;
	    return 0 if $njobs;

	    $new_job_args{slug} = $settings{'NAME'};
    }

    my $job = $schema->resultset("Jobs")->create(\%new_job_args);

    return $job->id;
}

sub job_get($) {
    my $value = shift;

    if ($value =~ /^\d+$/) {
	return _job_get({ id => $value });
    }
    return _job_get({slug => $value });
}

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;

    my $job = $schema->resultset("Jobs")->search($search)->first;
    my $job_hashref;
    if ($job) {
	$job_hashref = _hashref($job, qw/ id name priority worker_id t_started t_finished test test_branch/);
	# XXX: use +columns in query above?
	$job_hashref->{state} = $job->state->name;
	$job_hashref->{result} = $job->result->name;
	_job_fill_settings($job_hashref);
    }
    return $job_hashref;
}

sub _job_fill_settings {
    my $job = shift;
    my $job_settings = $schema->resultset("JobSettings")->search({ job_id => $job->{id} });
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
	my $states_rs = $schema->resultset("JobStates")->search({ name => [split(',', $args{state})] });
	$cond{state_id} = { -in => $states_rs->get_column("id")->as_query }
    }
    if ($args{maxage}) {
        my $agecond = { '>' => time2str('%Y-%m-%d %H:%M:%S', time - $args{maxage}, 'UTC') };
        $cond{'-or'} = [
            t_created => $agecond,
            t_started => $agecond,
            t_finished => $agecond
        ];
    }
    if ($args{build}) {
        $cond{'settings.key'} = "BUILD";
        $cond{'settings.value'} = $args{build};
        $attrs{join} = 'settings';
    }

    my $jobs = $schema->resultset("Jobs")->search(\%cond, \%attrs);

    my @results = ();
    while( my $job = $jobs->next) {
	my $j = _hashref($job, qw/ id name priority worker_id t_started t_finished test test_branch/);
	$j->{state} = $job->state->name;
	$j->{result} = $job->result->name;
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
	$result = $schema->resultset("Jobs")->search({
	    state_id => $schema->resultset("JobStates")->search({ name => "scheduled" })->single->id,
	    worker_id => 0,
	}, { order_by => { -asc => 'priority'}, rows => 1})->update({
	    state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
	    worker_id => $workerid,
	    t_started => \$now,
	});

	last if $result != 0;
	last unless $blocking;
	# XXX: do something smarter here
	#print STDERR "no jobs for me, sleeping\n";
	#sleep 1;
	last;
    }

    my $job_hashref;
    $job_hashref = _job_get({
	id => $schema->resultset("Jobs")->search({
		  state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
		  worker_id => $workerid,
	      })->single->id,
    }) if $result != 0;

    return $job_hashref;
}

=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters    
sub job_set_done {
    my %args = @_;
    my $jobid = int($args{jobid});
    my $result = $schema->resultset("JobResults")->search({ name => $args{result}})->single;

    die "invalid result string" unless $result;

    my $now = "datetime('now')";
    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "done" })->single->id,
	worker_id => 0,
	t_finished => \$now,
	result_id => $result->id,
    });
    return $r;
}

=item job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    # TODO: only allowed for running jobs
    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "waiting" })->single->id,
    });
    return $r;
}

=item job_set_running

mark job as running. No error check. Meant to be called from worker!

=cut
sub job_set_running {
    my $jobid = shift;

    my $states_rs = $schema->resultset("JobStates")->search({ name => ['cancelled', 'waiting'] });
    my $r = $schema->resultset("Jobs")->search({
	id => $jobid,
        state_id => { -in => $states_rs->get_column("id")->as_query },
    })->update({
	state_id => $schema->resultset("JobStates")->search({ name => "running" })->single->id,
    });
    return $r;
}

sub job_set_prio {
    my %args = @_;

    my $r = $schema->resultset("Jobs")->search({ id => $args{jobid} })->update({
	priority => $args{prio},
    });
}

sub job_delete {
    my $value = shift;

    my $cnt = 0;
    my $jobs = _job_find_smart($value);
    foreach my $job ($jobs) {
	my $r = $job->delete;
	$cnt += $r if $r != 0;
    }
    return $cnt;
}

sub job_update_result {
    my %args = @_;

    my $id = int($args{jobid});
    my $result = $schema->resultset("JobResults")->search({ name => $args{result}})->single;

    my $r = $schema->resultset("Jobs")->search({ id => $id })->update({
		    result_id => $result->id
	    });

    return $r;
}

sub _job_find_smart($) {
    my $value = shift;

    my $jobs;
    if ($value =~ /^\d+$/ ) {
	$jobs = _job_find_by_id($value);
    } elsif ($value =~ /\.iso$/) {
	$jobs = _jobs_find_by_iso($value);
    } else {
	$jobs = _job_find_by_name($value);
    }

    return $jobs;
}

sub _job_find_by_id($) {
    my $id = shift;
    my $jobs = $schema->resultset("Jobs")->search({ id => $id});
}

sub _jobs_find_by_iso($) {
    my $iso = shift;

    # In case iso file use a absolute path
    # like iso_delete /var/lib/.../xxx.iso
    if ($iso =~ /\// ) {
	$iso =~ s#^.*/##;
    }

    my $jobs = $schema->resultset("Jobs")->search_related("settings", {
	key => "ISO",
	value => $iso,
    });
    return $jobs;
}

sub _job_find_by_name($) {
    my $name = shift;

    my $jobs = $schema->resultset("Jobs")->search({ slug => $name });
    return $jobs;
}

sub job_duplicate {
    my %args = @_;

    print STDERR "duplicating $args{jobid}\n";

    my $job = _job_get({ id => $args{jobid} });
    return undef unless $job;

    my %settings = %{$job->{settings}};
    delete $settings{NAME};
    $settings{TEST} = $job->{test};
    # TODO: test_branch

    my $id = job_create(%settings);
    if (defined $id) {
        job_set_prio(jobid => $id, prio => $args{prio} || $job->{priority})
    }

    print STDERR "new job $id\n";

    return $id;
}

sub job_restart {
    my $name = shift or die "missing name parameter\n";

    # TODO: support by name and by iso here
    my $idqry = $name;

    # first, duplicate all jobs that are either running, waiting or done
    my $jobs = $schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => $schema->resultset("JobStates")->search({ name => [qw/running waiting done/] })->get_column("id")->as_query
            }
        }, {
            columns => [qw/id/]
        });
    while (my $j = $jobs->next) {
        job_duplicate(jobid => $j->id);
    }

    # then tell workers to abort
    $jobs = $schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => $schema->resultset("JobStates")->search({ name => [qw/running waiting/] })->get_column("id")->as_query
            }
        }, {
            colums => [qw/id worker_id/]
        });
    while (my $j = $jobs->next) {
        print STDERR "enqueuing ".$j->id." ".$j->worker_id."\n";
        command_enqueue(workerid => $j->worker_id, command => 'abort');
    }

    # now set all cancelled jobs to scheduled again
    $schema->resultset("Jobs")->search(
        {
            id => $idqry,
            state_id => {
                -in => $schema->resultset("JobStates")->search({ name => [qw/cancelled/] })->get_column("id")->as_query
            }
        }, {
    })->update({
        state_id => $schema->resultset("JobStates")->search({ name => 'scheduled' })->single->id
    });
}

sub job_cancel {
    my $value = shift or die "missing name parameter\n";

    my %attrs;
    my %cond;
    if (ref $value eq '') {
        if ($value =~ /\.iso/) {
            $value = { ISO => $value };
        }
    }
    if (ref $value eq 'HASH') {
        while (my ($k, $v) = each %$value) {
            $cond{'settings.key'} = $k;
            $cond{'settings.value'} = $v;
        }
        $attrs{join} = 'settings';
    } else {
        # TODO: support by name and by iso here
        $cond{id} = $value;
    }

    $cond{state_id} = {
        -in => $schema->resultset("JobStates")->search({ name => [qw/scheduled/] })->get_column("id")->as_query
    };

    # first set all scheduled jobs to cancelled
    $schema->resultset("Jobs")->search(\%cond, \%attrs)->update({
        state_id => $schema->resultset("JobStates")->search({ name => 'cancelled' })->single->id
    });

    $attrs{colums} = [qw/id worker_id/];
    $cond{state_id} = {
        -in => $schema->resultset("JobStates")->search({ name => [qw/running waiting/] })->get_column("id")->as_query
    };
    # then tell workers to cancel their jobs
    my $jobs = $schema->resultset("Jobs")->search(\%cond, \%attrs);
    while (my $j = $jobs->next) {
        print STDERR "enqueuing ".$j->id." ".$j->worker_id."\n";
        command_enqueue(workerid => $j->worker_id, command => 'cancel');
    }
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

    my $command = $schema->resultset("Commands")->create({
	worker_id => $args{workerid},
	command => $args{command},
    });
    return $command->id;
}

sub command_get {
    my $workerid = shift;

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my @commands = $schema->resultset("Commands")->search({ worker_id => $workerid });

    my @as_array = ();
    foreach my $command (@commands) {
	push @as_array, [$command->id, $command->command];
    }

    return \@as_array;
}

sub list_commands {
    my $rs = $schema->resultset("Commands");
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @commands = $rs->all;

    return \@commands;
}

sub command_dequeue {
    my %args = @_;

    die "missing workerid parameter\n" unless $args{workerid};
    die "missing id parameter\n" unless $args{id};

    _validate_workerid($args{workerid});

    my $r = $schema->resultset("Commands")->search({
	id => $args{id},
	worker_id =>$args{workerid},
    })->delete;

    return $r;
}

1;
