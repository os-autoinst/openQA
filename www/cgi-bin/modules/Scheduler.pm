package Scheduler;

use strict;
use DBI;
use Digest::MD5;
#use List::Util qw/shuffle/;
#use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
use openqa ();

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw(ob_fill_settings list_jobs list_workers worker_register job_grab
 job_set_scheduled job_set_done job_set_stop job_set_waiting job_set_running job_create job_set_prio
 job_delete job_update_result job_find_by_name($;@) job_restart_by_name
 command_get command_enqueue command_dequeue list_commands);


my $get_job_stmt = "SELECT
	jobs.id as id,
	jobs.name as name,
	job_state.name as state,
	jobs.priority as priority,
	jobs.result as result,
	jobs.worker as worker,
	jobs.start_date as start_date,
	jobs.finish_date as finish_date
	from jobs, job_state
	where jobs.state = job_state.id";

my $dbh = DBI->connect("dbi:SQLite:dbname=$openqa::dbfile","","");
$dbh->{RaiseError} = 1;
$dbh->do("PRAGMA foreign_keys = ON");

# in the hope to make it faster
# http://www.sqlite.org/pragma.html#pragma_synchronous
$dbh->do("PRAGMA synchronous = OFF;");

sub job_fill_settings
{
    my $job = shift;
    my $sth = $dbh->prepare("SELECT key, value from job_settings where job_settings.jobid = ?");
    my $rc = $sth->execute($job->{'id'});
    $job->{settings} = {};
    while(my @row = $sth->fetchrow_array) {
        $job->{settings}->{$row[0]} = $row[1];
    }
    return $job;
}

sub list_jobs
{
    my %args = @_;
    my @params;
    my $stmt = $get_job_stmt;
    if ($args{'state'}) {
	my @states = split(',', $args{'state'});
	$stmt .= " AND job_state.name IN (?".",?"x$#states.")";
	push @params, @states;
    }
    if ($args{'finish_after'}) {
	$stmt .= " AND jobs.finish_date > datetime(?)";
	push @params, $args{'finish_after'};
    }
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@params);
    
    my $jobs = [];
    while(my $job = $sth->fetchrow_hashref) {
        job_fill_settings($job);
        push @$jobs, $job;
    }
    return $jobs;
}

sub _seen_worker($)
{
    my $id = shift;
    my $sth = $dbh->prepare("UPDATE worker SET seen = datetime('now') WHERE id = ?");
    $sth->execute($id) or die "SQL failed\n";
}

sub list_workers
{
    my $stmt = "SELECT id, host, instance, backend, seen from worker";
    my $sth = $dbh->prepare($stmt);
    $sth->execute();
    
    my $workers = [];
    while(my $worker = $sth->fetchrow_hashref) {
        push @$workers, $worker;
    }
    return $workers;
}

# param hash: host, instance, backend
sub worker_register
{
    my %args = @_;
    
    my $sth = $dbh->prepare("SELECT id, backend from worker where host = ? and instance = ?");
    my $r = $sth->execute($args{'host'}, $args{'instance'}) or die "SQL failed\n";
    my @row = $sth->fetchrow_array();

    my $id;
    if (@row) { # worker already known. Update fields and return id
        $id = $row[0];
        $sth = $dbh->prepare("UPDATE worker SET seen = datetime('now'), backend = ? WHERE id = ?");
        $r = $sth->execute($args{'backend'}, $id) or die "SQL failed\n";
    } else {
        $sth = $dbh->prepare("INSERT INTO worker (host, instance, backend, seen) values (?,?,?, datetime('now'))");
        $sth->execute($args{host}, $args{instance}, $args{backend});
        $id = $dbh->last_insert_id(undef,undef,undef,undef);
    }
    
    
    # maybe worker died, delete pending commands and reset running jobs
    my $state = "(select id from job_state where name = 'scheduled' limit 1)";
    $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, start_date = NULL, finish_date = NULL, result = NULL WHERE worker = ?");
    $r = $sth->execute($id) or die $dbh->errstr;
    
    $sth = $dbh->prepare("DELETE FROM commands WHERE worker = ?");
    $r = $sth->execute($id) or die $dbh->errstr;
    
    die "got invalid id" unless $id;
    return $id;
}

#sub get_statenames()
#{
#	my $sth = $dbh->prepare('SELECT id, name from job_state');
#	$sth->execute();
#	my $h = { map { $_->[1] => $_->[0] } @{$sth->fetchall_arrayref()} };
#	return $h;
#}

sub _validate_workerid($)
{
    my $workerid = shift;

    die "invalid worker id\n" unless $workerid;

    my $sth = $dbh->prepare("SELECT id from worker where id == ?");
    $sth->execute($workerid);
    my $res = $sth->fetchall_arrayref;
    die "invalid worker id $workerid\n" unless @$res && @$res == 1 && $res->[0]->[0] == $workerid;
}

sub _job_get($;$)
{
    my $jobid = shift;
    my $cond = shift;

    my $stmt = $get_job_stmt;
    $stmt .= $cond if $cond;

    my $sth = $dbh->prepare($stmt);
    $sth->execute($jobid) or die "$!\n";

    my $job = $sth->fetchrow_hashref;
    job_fill_settings($job);

    return $job;
}

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab
{
    my %args = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my $job;
    while (1) {
        my $sth = $dbh->prepare("SELECT id FROM jobs WHERE state == 1 ORDER BY priority");
        $sth->execute;
        my @jobids;
        while(my @row = $sth->fetchrow_array) {
            push @jobids, $row[0];
        }

        if (@jobids) {
            # run through all job ids and try to grab one
            for my $jobid (@jobids) {
                $dbh->begin_work;
                eval {
		    my $state = "(select id from job_state where name = 'running' limit 1)";
                    my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = ?, start_date = datetime('now'), result = NULL WHERE id = ?");
                    $sth->execute($workerid, $jobid);
                    $dbh->commit;

                    $job = _job_get($jobid, ' and jobs.id = ?');
                };
                if ($@) {
                    print STDERR "$@\n";
                    eval { $dbh->rollback };
                    next;
                }
                last;
            }
        }

        last if $job;
        last unless $blocking;
        # XXX: do something smarter here
        #print STDERR "no jobs for me, sleeping\n";
        #sleep 1;
        last;
    }

    return $job;
}

sub job_get($)
{
    my $jobid = shift;

    if ($jobid =~ /^\d+$/) {
	return _job_get($jobid, ' and jobs.id = ?');
    }
    return _job_get($jobid, ' and jobs.name = ?');
}

=head2
release job from a worker and put back to scheduled (e.g. if worker aborted). No error check. Meant to be called from worker!
=cut
sub job_set_scheduled
{
    my $jobid = shift;

    my $state = "(select id from job_state where name = 'scheduled' limit 1)";
    my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, start_date = NULL, finish_date = NULL, result = NULL WHERE id = ?");
    my $r = $sth->execute($jobid) or die $dbh->errstr;
    return $r;
}

=head2
mark job as done. No error check. Meant to be called from worker!
=cut
sub job_set_done
{
    my %args = @_;
    my $jobid = int($args{jobid});
    my $result = $args{result};

    my $state = "(select id from job_state where name = 'done' limit 1)";
    my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, finish_date = datetime('now'), result = ? WHERE id = ?");
    my $r = $sth->execute($result, $jobid) or die $dbh->errstr;
    return $r;
}

=head2
mark job as stopped. No error check. Meant to be called from worker!
=cut
sub job_set_stop
{
    my $jobid = shift;

    my $state = "(select id from job_state where name = 'stopped' limit 1)";
    my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0 WHERE id = ?");
    my $r = $sth->execute($jobid) or die $dbh->errstr;
    return $r;
}

=head2
mark job as waiting. No error check. Meant to be called from worker!
=cut
sub job_set_waiting
{
    my $jobid = shift;

    my $state = "(select id from job_state where name = 'waiting' limit 1)";
    my $sth = $dbh->prepare("UPDATE jobs set state = $state WHERE id = ?");
    my $r = $sth->execute($jobid) or die $dbh->errstr;
    return $r;
}

=head2
mark job as running. No error check. Meant to be called from worker!
=cut
sub job_set_running
{
    my $jobid = shift;

    my $state = "(select id from job_state where name = 'running' limit 1)";
    my $sth = $dbh->prepare("UPDATE jobs set state = $state WHERE id = ? AND state IN (SELECT id from job_state WHERE name IN ('stopped', 'waiting'))");
    my $r = $sth->execute($jobid) or die $dbh->errstr;
    return $r;
}

=head2
create a job
=cut
sub job_create
{
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

    $dbh->begin_work;
    my $id = 0;
    eval {
        my $sth = $dbh->prepare("INSERT INTO jobs (name) VALUES(?)");
        my $rc = $sth->execute($settings{'NAME'});
        $id = $dbh->last_insert_id(undef,undef,undef,undef);
        die "got invalid id" unless $id;
        while(my ($k, $v) = each %settings) {
            my $sth = $dbh->prepare("INSERT INTO job_settings (jobid, key, value) values (?, ?, ?)");
            $sth->execute($id, $k, $v);
        }
        $dbh->commit;
    };
    if ($@) {
        print STDERR "$@\n";
        eval { $dbh->rollback };
    }
    return $id;
}

sub job_set_prio
{
    my %args = @_;
    
    my $sth = $dbh->prepare("UPDATE jobs SET priority = ? where id = ?");
    my $r = $sth->execute(int($args{prio}), int($args{jobid})) or die $dbh->error;
    return $r;
}

sub job_delete
{
    my $jobid = int(shift);

    $dbh->begin_work;
    my $r;
    eval {
        my $sth = $dbh->prepare("DELETE FROM job_settings WHERE jobid = ?");
        $sth->execute($jobid);
        $sth = $dbh->prepare("DELETE FROM jobs WHERE id = ?");
        $r = $sth->execute($jobid);
        $dbh->commit;
    };
    if ($@) {
        print STDERR "$@\n";
        eval { $dbh->rollback };
    }
    return $r;
}

sub job_update_result
{
    my %args = @_;

    my $id = int($args{jobid});
    my $result = $args{result};

    my $sth = $dbh->prepare("UPDATE jobs SET result = ? where id = ?");
    my $r = $sth->execute($result, $id) or die $dbh->error;
    return $r;
}

sub _job_find_by_name($;@)
{
    my $name = shift;
    my @cols = @_;
    @cols = ('id') unless @_;

    my $sth = $dbh->prepare("SELECT ".join(',', @cols)." FROM jobs WHERE name = ?");
    my $rc = $sth->execute($name);
    return $sth;
}

sub _jobs_find_by_iso($;@)
{
    my $iso = shift;
    my @cols = @_;
    @cols = ('id') unless @_;

    my $sth = $dbh->prepare("SELECT ".join(',', @cols)." FROM jobs, job_settings"
	    . " WHERE jobs.id == job_settings.jobid"
	    . " AND job_settings.key == 'ISO'"
	    . " AND job_settings.value == ?");
    my $rc = $sth->execute($iso);
    return $sth;
}

sub _job_find_by_id($;@)
{
    my $id = shift;
    my @cols = @_;
    @cols = ('id') unless @_;

    my $sth = $dbh->prepare("SELECT ".join(',', @cols)." FROM jobs WHERE id = ?");
    my $rc = $sth->execute($id);
    return $sth;
}

# set job to a final state, resetting it's properties
# parameters:
# - id or name
# - command to send to worker if the job is in use
# - name of final state
sub _job_set_final_state($$$)
{
    my $name = shift;
    my $cmd = shift;
    my $statename = shift;

    # needs to be a transaction as we need to make sure no worker assigns
    # itself while we modify the job
    $dbh->begin_work;
    eval {
	my $sth;
	if ($name =~ /^\d+$/ ) {
		$sth = _job_find_by_id($name, 'id', 'worker');
	} elsif ($name =~ /\.iso$/) {
		$sth = _jobs_find_by_iso($name, 'id', 'worker');
	} else {
		$sth = _job_find_by_name($name, 'id', 'worker');
	}

	while (my ($id, $workerid) = @{$sth->fetchrow_arrayref||[]}) {
	    print STDERR "workerid $id, $workerid -> $cmd\n";
	    if ($workerid) {
		my $sth = $dbh->prepare("INSERT INTO commands (worker, command) VALUES(?, ?)");
		my $rc = $sth->execute($workerid, $cmd) or die $dbh->error;
	    } else {
		my $stateid = "(select id from job_state where name = '$statename' limit 1)";
		my $sth = $dbh->prepare("UPDATE jobs set state = $stateid, worker = 0, start_date = NULL, finish_date = NULL, result = NULL WHERE id = ?");
		my $r = $sth->execute($id) or die $dbh->errstr;

	    }
	}
        $dbh->commit;
    };
    if ($@) {
        print STDERR "$@\n";
        eval { $dbh->rollback };
        return;
    }
}

sub job_restart
{
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "abort", "scheduled");
}

sub job_stop
{
    my $name = shift or die "missing name parameter\n";
    return _job_set_final_state($name, "stop", "stopped");
}

sub command_get
{
    my $workerid = shift;

    _validate_workerid($workerid);
    _seen_worker($workerid);

    my $sth = $dbh->prepare("SELECT id, command FROM commands WHERE worker = ?");
    my $r = $sth->execute($workerid) or die $dbh->errstr;

    my $commands = $sth->fetchall_arrayref;

    return $commands;
}

sub command_enqueue
{
    my %args = @_;

    _validate_workerid($args{workerid});

    my $sth = $dbh->prepare("INSERT INTO commands (worker, command) VALUES(?, ?)");
    my $rc = $sth->execute($args{workerid}, $args{command}) or die $dbh->error;

    return $dbh->last_insert_id(undef,undef,undef,undef);
}

sub command_dequeue
{
    my %args = @_;

    die "missing workerid parameter\n" unless $args{workerid};
    die "missing id parameter\n" unless $args{id};

    _validate_workerid($args{workerid});

    my $sth = $dbh->prepare("DELETE FROM commands WHERE id = ? and worker = ?");
    my $r = $sth->execute($args{id}, $args{workerid});
    
    return int($r);
}

sub list_commands
{
    my $sth = $dbh->prepare("select * from commands");
    $sth->execute();

    my $commands = [];
    while(my $command = $sth->fetchrow_hashref) {
        push @$commands, $command;
    }
    return $commands;
}
