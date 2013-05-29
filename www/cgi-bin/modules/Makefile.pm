package Makefile;

use base qw(JSON::RPC::Procedure);

use strict;
use DBI;
use List::Util qw/shuffle/;
use Data::Dump qw/pp/;

use lib "$FindBin::Bin/modules";
use openqa ();

our $dbfile = '/var/lib/openqa/db';

our $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");
$dbh->{RaiseError} = 1;
$dbh->do("PRAGMA foreign_keys = ON");

sub echo : Public
{
	print STDERR pp \%ENV;
	return $_[1];
}

sub list_jobs : Public
{
	my $stmt = "SELECT
		jobs.id as id,
		job_state.name as state,
		jobs.priority as priority,
		jobs.result as result,
		jobs.worker as worker,
		jobs.start_date as start_date,
		jobs.finish_date as finish_date
		from jobs, job_state
		where jobs.state = job_state.id";
	my $sth = $dbh->prepare($stmt);
	$sth->execute();

	my $jobs = [];
	while(my $job = $sth->fetchrow_hashref) {
		my $sth2 = $dbh->prepare("SELECT key, value from job_settings where job_settings.jobid = ?");
		my $rc = $sth2->execute($job->{'id'});
		$job->{settings} = {};
		while(my @row = $sth2->fetchrow_array) {
			$job->{settings}->{$row[0]} = $row[1];
		}
		push @$jobs, $job;
	}
	return $jobs;
}

sub list_workers : Public
{
	my $stmt = "SELECT id, host, port, backend from worker";
	my $sth = $dbh->prepare($stmt);
	$sth->execute();

	my $workers = [];
	while(my $worker = $sth->fetchrow_hashref) {
		push @$workers, $worker;
	}
	return $workers;
}


sub worker_register : Num(host, port, backend)
{
	my $self = shift;
	my $args = shift;

	my $sth = $dbh->prepare("INSERT into worker (host, port, backend) values (?,?,?)");
	$sth->execute($args->{host}, $args->{port}, $args->{backend});

	my $id = $dbh->last_insert_id(undef,undef,undef,undef);
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

=head2
takes worker id and a blocking argument
if I specify the parameters here the get exchanged in order, no idea why
=cut
# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab : Num
{
	my $self = shift;
	my $args = shift;
	my $workerid = shift @$args;
	my $blocking = int(shift @$args || 0);

	die "invalid worker id\n" unless $workerid;

	my $sth = $dbh->prepare("SELECT id from worker where id == ?");
	$sth->execute($workerid);
	{
		my $res = $sth->fetchall_arrayref;
		die "invalid worker id $workerid\n" unless @$res && @$res == 1 && $res->[0]->[0] == $workerid;
	}

	my $state = "(select id from job_state where name = 'running' limit 1)";

	my $id;
	while (1) {
		$sth = $dbh->prepare("SELECT id from jobs where state == 1");
		$sth->execute;
		my @jobids;
		while(my @row = $sth->fetchrow_array) {
			push @jobids, $row[0];
		}

		if (@jobids) {
			# run through all job ids and try to grab one
			for my $jobid (shuffle(@jobids)) {
				$dbh->begin_work;
				eval {
					# XXX: magic constant 2 == running
					my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = ?, start_date = datetime('now'), result = NULL WHERE id = ?");
					$sth->execute($workerid, $jobid);
					$dbh->commit;
				};
				if ($@) {
					print STDERR "$@\n";
					eval { $dbh->rollback };
					next;
				}
				$id = $jobid;
				last;
			}
		}

		last if $id;
		last unless $blocking;
		# XXX: do something smarter here
		#print STDERR "no jobs for me, sleeping\n";
		#sleep 1;
		$self->raise_error(code => 404, message => 'no open jobs atm');
		last;
	};
	return $id;;
}

=head2
release job from a worker and put back to scheduled (e.g. if worker aborted)
=cut
sub job_release : Public(id:num)
{
	my $self = shift;
	my $args = shift;
	my $jobid = $args->{id};

	my $state = "(select id from job_state where name = 'scheduled' limit 1)";
	my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, start_date = NULL, finish_date = NULL, result = NULL WHERE id = ?");
	my $r = $sth->execute($jobid) or die $dbh->errstr;
	$self->raise_error(code => 400, message => "failed to release job") unless $r == 1;
}

=head2
mark job as done
=cut
sub job_done : Public #(id:num, result)
{
	my $self = shift;
	my $args = shift;
	my $jobid = int(shift $args);
	my $result = shift $args;

	my $state = "(select id from job_state where name = 'done' limit 1)";
	my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, finish_date = datetime('now'), result = ? WHERE id = ?");
	my $r = $sth->execute($result, $jobid) or die $dbh->errstr;
	$self->raise_error(code => 400, message => "failed to finish job") unless $r == 1;
}

=head2
mark job as stopped
=cut
sub job_stop : Public(id:num)
{
	my $self = shift;
	my $args = shift;
	my $jobid = $args->{id};

	my $state = "(select id from job_state where name = 'stopped' limit 1)";
	my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0 WHERE id = ?");
	my $r = $sth->execute($jobid) or die $dbh->errstr;
	$self->raise_error(code => 400, message => "failed to stop job") unless $r == 1;
}

=head2
mark job as waiting
=cut
sub job_waiting : Public(id:num)
{
	my $self = shift;
	my $args = shift;
	my $jobid = $args->{id};

	my $state = "(select id from job_state where name = 'waiting' limit 1)";
	my $sth = $dbh->prepare("UPDATE jobs set state = $state WHERE id = ?");
	my $r = $sth->execute($jobid) or die $dbh->errstr;
	$self->raise_error(code => 400, message => "failed to set job to waiting") unless $r == 1;
}

=head2
mark job as waiting
=cut
sub job_continue : Public(id:num)
{
	my $self = shift;
	my $args = shift;
	my $jobid = $args->{id};

	my $state = "(select id from job_state where name = 'running' limit 1)";
	my $sth = $dbh->prepare("UPDATE jobs set state = $state WHERE id = ? AND state IN (SELECT id from job_state WHERE name IN ('stopped', 'waiting'))");
	my $r = $sth->execute($jobid) or die $dbh->errstr;
	$self->raise_error(code => 400, message => "failed to continue job") unless $r == 1;
}


=head2
create a job, expects key=value pairs
=cut
sub job_create : Num
{
	my $self = shift;
	my $args = shift;
	my %settings;
	die "invalid arguments" unless ref $args eq 'ARRAY';
	for my $i (@$args) {
		die "invalid argument\n" unless $i =~ /^([A-Z]+)=([^\s]+)$/;
		$settings{$1} = $2;
	}
	for my $i (qw/DISTRI ISO DESKTOP/) {
		die "need at least one $i key\n" unless exists $settings{$i};
	}
	unless (-e sprintf("%s/%s/factory/iso/%s",
		$openqa::basedir, $openqa::prj, $settings{ISO})) {
		die "ISO does not exist\n";
	}
	$dbh->begin_work;
	my $id = 0;
	eval {
		my $rc = $dbh->do("INSERT INTO jobs DEFAULT VALUES");
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

sub job_set_prio : Public #(id:num, prio:num)
{
	my $self = shift;
	my $args = shift;
	my $id = int(shift $args);
	my $prio = int(shift $args);
	my $sth = $dbh->prepare("UPDATE jobs SET priority = ? where id = ?");
	my $r = $sth->execute($prio, $id) or die $dbh->error;
	$self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

sub job_delete : Public(id:num)
{
	my $self = shift;
	my $args = shift;
	my $id = int($args->{id});

	$dbh->begin_work;
	my $r = 0;
	eval {
		my $sth = $dbh->prepare("DELETE FROM job_settings WHERE jobid = ?");
		$sth->execute($id);
		$sth = $dbh->prepare("DELETE FROM jobs WHERE id = ?");
		$r = $sth->execute($id);
		$dbh->commit;
	};
	if ($@) {
		print STDERR "$@\n";
		eval { $dbh->rollback };
	}
	$self->raise_error(code => 400, message => "didn't delete anything") unless $r == 1;
}

sub job_update_result : Public #(id:num, result)
{
	my $self = shift;
	my $args = shift;
	my $id = int(shift $args);
	my $result = shift $args;

	my $sth = $dbh->prepare("UPDATE jobs SET result = ? where id = ?");
	my $r = $sth->execute($result, $id) or die $dbh->error;
	$self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

1;
