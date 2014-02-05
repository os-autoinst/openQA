package Scheduler;

use strict;
use warnings;
use diagnostics;

use DBIx::Class::ResultClass::HashRefInflator;
use Digest::MD5;
use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
#use lib $FindBin::Bin.'Schema';
use Schema::Schema; 
use openqa ();


require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);

@EXPORT = qw(worker_register worker_get list_workers job_create
    job_get list_jobs job_grab job_set_scheduled job_set_done
    job_set_stop job_set_waiting job_set_running job_set_prio
    job_delete job_update_result job_restart job_stop command_enqueue
    command_get list_commands command_dequeue iso_stop_old_builds);


my $schema = Schema->connect({
    dsn => "dbi:SQLite:dbname=$openqa::dbfile",
    on_connect_call => "use_foreign_keys",
});


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
	instance => $instance,
    })->first;

    my $now = "datetime('now')";
    if ($worker) { # worker already known. Update fields and return id
	$worker->update({
	    seen => \$now,
	});
    } else {
	$worker = $schema->resultset("Workers")->create({
	    host => $host,
	    instance => $instance,
	    backend => $backend,
	    seen => \$now,
	});
    }

    # maybe worker died, delete pending commands and reset running jobs
    $worker->jobs->update_all({
	state_id => $schema->resultset("JobState")->search({ name => "scheduled" })->single->id,
    });
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
    my $now = "datetime('now')";
    $schema->resultset("Workers")->find($id)->update({ seen => \$now });
}


#
# Jobs API
#

=item job_create

create a job

=cut
sub job_create {
    my %settings = @_;

    for my $i (qw/DISTRI ISO DESKTOP/) {
	die "need at least one $i key\n" unless exists $settings{$i};
    }

    for my $i (qw/ISO NAME/) {
	next unless $settings{$i};
	die "invalid character in $i\n" if $settings{$i} =~ /\//; # TODO: use whitelist?
    }

    unless (-e sprintf("%s/%s/factory/iso/%s",
		       $openqa::basedir, $openqa::prj, $settings{ISO})) {
	die "ISO does not exist\n";
    }

    unless ($settings{NAME}) {
	my $ctx = Digest::MD5->new;
	for my $k (sort keys %settings) {
	    $ctx->add($settings{$k});
	}

	my $name = $settings{ISO};
	$name =~ s/\.iso$//;
	$name =~ s/-Media$//;
	$name .= '-';
	$name .= $settings{DESKTOP};
	$name .= '_'.$settings{VIDEOMODE} if $settings{VIDEOMODE};
	$name .= '_'.substr($ctx->hexdigest, 0, 6);
	$settings{NAME} = $name;
    }

    unless (-e sprintf("%s/%s/factory/iso/%s",
		       $openqa::basedir, $openqa::prj, $settings{ISO})) {
	die "ISO does not exist\n";
    }

    unless ($settings{ISO_MAXSIZE}) {
	my $maxsize = 737_280_000;
	if ($settings{ISO} =~ /-DVD/) {
	    if ($settings{ISO} =~ /-DVD-Biarch/) {
		$maxsize=8_539_996_160;
	    } else {
		$maxsize=4_700_372_992;
	    }
	}
	# live images are for 1G sticks
	if ($settings{ISO} =~ /-Live/ && $settings{ISO} !~ /CD/) {
	    $maxsize=999_999_999;
	}

	$settings{ISO_MAXSIZE} = $maxsize;
    }

    my @settings = ();
    while(my ($k, $v) = each %settings) {
	push @settings, { key => $k, value => $v };
    }

    my $jobs = $schema->resultset("Jobs")->search({ name => $settings{'NAME'} });
    return 0 if $jobs->count;

    my $job = $schema->resultset("Jobs")->create({
	name => $settings{'NAME'},
	settings => \@settings,
    });

    return $job->id;
}

sub job_get($) {
    my $value = shift;

    if ($value =~ /^\d+$/) {
	return _job_get({ id => $value });
    }
    return _job_get({name => $value });
}

# XXX TODO: Do not expand the Job
sub _job_get($) {
    my $search = shift;

    my $job = $schema->resultset("Jobs")->search($search)->first;
    my $job_hashref;
    if ($job) {
	$job_hashref = _hashref($job, qw/ id name priority result worker_id start_date finish_date /);
	$job_hashref->{state} = $job->state->name;
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

    return $job;
}

sub list_jobs {
    my %args = @_;

    my %search = ();
    if ($args{state}) {
	$search{states} = { '-in' => split(',', $args{state}) }
    }
    if ($args{finish_after}) {
	my $param = "datetime($args{finish_after})";
	$search{finish_date} = { '>' => \$param }
    }
    if ($args{build}) {
	my $param = sprintf("%%-Build%04d-%%", $args{build});
	$search{build} = { like => $param }
    }
    my @jobs = $schema->resultset("Jobs")->all();

    my @results = ();
    for my $job (@jobs) {
	my $j = _hashref($job, qw/ id name priority result worker_id start_date finish_date /);
	$j->{state} = $job->state->name;
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
	    state_id => $schema->resultset("JobState")->search({ name => "scheduled" })->single->id,
	    worker_id => 0,
	})->get_column("pritority")->max_rs->update({
	    state_id => $schema->resultset("JobState")->search({ name => "running" })->single->id,
	    worker_id => $workerid,
	    start_date => \$now,
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
		  state_id => $schema->resultset("JobState")->search({ name => "running" })->single->id,
		  worker_id => $workerid,
	      })->single->id,
    }) if $result != 0;

    return $job_hashref;
}

=item job_set_scheduled

release job from a worker and put back to scheduled (e.g. if worker
aborted). No error check. Meant to be called from worker!

=cut
sub job_set_scheduled {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobState")->search({ name => "scheduled" })->single->id,
	worker_id => 0,
	start_date => undef,
	finish_date => undef,
	result => undef,
    });
    return $r;
}

=item job_set_done

mark job as done. No error check. Meant to be called from worker!

=cut
# XXX TODO Parameters is a hash, check if is better use normal parameters    
sub job_set_done {
    my %args = @_;
    my $jobid = int($args{jobid});
    my $result = $args{result};

    my $now = "datetime('now')";
    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobState")->search({ name => "done" })->single->id,
	worker_id => 0,
	finish_date => \$now,
	result => $result,
    });
    return $r;
}

=item job_set_stop

mark job as stopped. No error check. Meant to be called from worker!

=cut
sub job_set_stop {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobState")->search({ name => "stopped" })->single->id,
	worker_id => 0,
    });
    return $r;
}

=item job_set_waiting

mark job as waiting. No error check. Meant to be called from worker!

=cut
sub job_set_waiting {
    my $jobid = shift;

    my $r = $schema->resultset("Jobs")->search({ id => $jobid })->update({
	state_id => $schema->resultset("JobState")->search({ name => "waiting" })->single->id,
    });
    return $r;
}

=item job_set_running

mark job as running. No error check. Meant to be called from worker!

=cut
sub job_set_running {
    my $jobid = shift;

    my $states_rs = $schema->resultset("JobState")->search({ name => ['stopped', 'waiting'] });
    my $r = $schema->resultset("Jobs")->search({
	id => $jobid,
        state_id => { -in => $states_rs->get_column("id")->as_query },
    })->update({
	state_id => $schema->resultset("JobState")->search({ name => "running" })->single->id,
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
    my $result = $args{result};

    my $r = $schema->resultset("Jobs")->search({ id => $id })->update({ result => $result });

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

    my $jobs = $schema->resultset("Jobs")->search({ name => $name });
    return $jobs;
}

sub job_restart {
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "abort", "scheduled");
}

sub job_stop {
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "stop", "stopped");
}

# set job to a final state, resetting it's properties
# parameters:
# - id or name
# - command to send to worker if the job is in use
# - name of final state
sub _job_set_final_state($$$) {
    my $name = shift;
    my $cmd = shift;
    my $statename = shift;

    # XXX TODO Put this into a transaction
    # needs to be a transaction as we need to make sure no worker assigns
    # itself while we modify the job
    my $jobs = _job_find_smart($name);
    foreach my $job ($jobs->next) {
	print STDERR "workerid ". $job->id . ", " . $job->worker_id . " -> $cmd\n";
	if ($job->worker_id) {
	    $schema->resultset("Commands")->create({
		worker_id => $job->worker_id,
		command => $cmd,
	    });
	} else {
	    # XXX This do not make sense
	    $job->update({
		state_id => $schema->resultset("JobState")->search({ name => $statename })->single->id,
		worker_id => 0,
	    });
	}
    }
}


#
# Commands API
#

sub command_enqueue {
    my %args = @_;

    _validate_workerid($args{workerid});

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
	id => $args{workerid},
	worker_id =>$args{workerid},
    })->delete;

    return $r;
}

# XXX TODO this is wrong, the semantic of stopping jobs here is different from job_stop()
sub iso_stop_old_builds($) {
    my $pattern = shift;

    my $r = $schema->resultset("Jobs")->search({
	state_id => $schema->resultset("JobState")->search({ name => "scheduled" })->single->id,
	'settings.key' => "ISO",
	'settings.value' => { like => $pattern },
    }, {
	join => "settings",
    })->update({
	state_id => $schema->resultset("JobState")->search({ name => "stopped" })->single->id,
	worker_id => 0,
    });
    return $r;
}
