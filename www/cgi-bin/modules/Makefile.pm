package Makefile;

use base qw(JSON::RPC::Procedure);

use strict;
use DBI;
use List::Util qw/shuffle/;
use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
use openqa ();

our $get_job_stmt = "SELECT
	jobs.id as id,
	job_state.name as state,
	jobs.priority as priority,
	jobs.result as result,
	jobs.worker as worker,
	jobs.start_date as start_date,
	jobs.finish_date as finish_date
	from jobs, job_state
	where jobs.state = job_state.id";

our $dbh = DBI->connect("dbi:SQLite:dbname=$openqa::dbfile","","");
$dbh->{RaiseError} = 1;
$dbh->do("PRAGMA foreign_keys = ON");

sub echo : Public
{
	print STDERR pp \%ENV;
	return $_[1];
}

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

sub list_jobs : Public
{
	my $sth = $dbh->prepare($get_job_stmt);
	$sth->execute();

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

sub list_workers : Public
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


sub worker_register : Num(host, instance, backend)
{
	my $self = shift;
	my $args = shift;

	my $sth = $dbh->prepare("SELECT id, backend from worker where host = ? and instance = ?");
	my $r = $sth->execute($args->{'host'}, $args->{'instance'}) or die "SQL failed\n";
	my @row = $sth->fetchrow_array();

	my $id;
	if (@row) { # worker already known. Update fields and return id
		$id = $row[0];
		$sth = $dbh->prepare("UPDATE worker SET seen = datetime('now'), backend = ? WHERE id = ?");
		$r = $sth->execute($args->{'backend'}, $id) or die "SQL failed\n";
	} else {
		$sth = $dbh->prepare("INSERT INTO worker (host, instance, backend, seen) values (?,?,?, datetime('now'))");
		$sth->execute($args->{host}, $args->{instance}, $args->{backend});
		$id = $dbh->last_insert_id(undef,undef,undef,undef);
	}

	# maybe worker died, delete pending commands
	$sth = $dbh->prepare("DELETE FROM commands WHERE worker = ?");
	$r = $sth->execute($id);

	die "got invalid id" unless $id;
	return $id;
}

sub iso_new : Num(iso)
{
	my $self = shift;
	my $args = shift;

	my %testruns = ( 64 => {'QEMUCPU' => 'qemu64'},
			 RAID0 => {'RAIDLEVEL' => '0'},
			 RAID1 => {'RAIDLEVEL' => '1'},
			 RAID10 => {'RAIDLEVEL' => '10'},
			 RAID5 => {'RAIDLEVEL' => '5'},
			 btrfs => {'BTRFS' => '1'},
			 btrfscryptlvm => {'BTRFS' => '1', 'ENCRYPT' => '1', 'LVM' => '1'},
			 cryptlvm => {'REBOOTAFTERINSTALL' => '0', 'ENCRYPT' => '1', 'LVM' => '1'},
			 de => {'DOCRUN' => '1', 'INSTLANG' => 'de_DE', 'QEMUVGA' => 'std'},
			 doc => {'DOCRUN' => '1', 'QEMUVGA' => 'std'},
			 gnome => {'DESKTOP' => 'gnome', 'LVM' => '1'},
			 live => {'LIVETEST' => '1', 'REBOOTAFTERINSTALL' => '0'},
			 lxde => {'DESKTOP' => 'lxde', 'LVM' => '1'},
			 minimalx => {'DESKTOP' => 'minimalx'},
			 nice => {'NICEVIDEO' => '1', 'DOCRUN' => '1', 'REBOOTAFTERINSTALL' => '0', 'SCREENSHOTINTERVAL' => '0.25'},
			 smp => {'QEMUCPUS' => '4'},
			 splitusr => {'SPLITUSR' => '1'},
			 textmode => {'DESKTOP' => 'textmode', 'VIDEOMODE' => 'text'},
			 uefi => {'UEFI' => '/openqa/uefi', 'DESKTOP' => 'lxde'},
			 usbboot => {'USBBOOT' => '1', 'LIVETEST' => '1'},
			 usbinst => {'USBBOOT' => '1'},
                         xfce => {'DESKTOP' => 'xfce'}
        );

	(my $iso = $args->{iso}) =~ s|^.*/||;
	my $params = openqa::parse_iso($iso);

        my $cnt = 0;

	if ( $params ) {
            foreach my $run ( keys(%testruns) ) {
                my %env = (ISO => $iso, DISTRI => lc($params->{distri}), DESKTOP => 'KDE');
                @env{keys %{$testruns{$run}}} = values %{$testruns{$run}};
                my @env = map { $_.'='.$env{$_} } keys %env;
		$cnt++ if job_create( $self, \@env );
            }

	}

        return $cnt;
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

	_validate_workerid($workerid);
	_seen_worker($workerid);

	my $state = "(select id from job_state where name = 'running' limit 1)";

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
					# XXX: magic constant 2 == running
					my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = ?, start_date = datetime('now'), result = NULL WHERE id = ?");
					$sth->execute($workerid, $jobid);
					$dbh->commit;

					$sth = $dbh->prepare($get_job_stmt.' and jobs.id = ?');
					$sth->execute($jobid) or die "$!\n";
					$job = $sth->fetchrow_hashref;
					job_fill_settings($job);

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
		$self->raise_error(code => 404, message => 'no open jobs atm');
		last;
	};
	return $job;

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
		die "invalid argument: $i\n" unless $i =~ /^([A-Z]+)=([^\s]+)$/;
		$settings{$1} = $2;
	}
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
		use Digest::MD5;
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

sub command_get : Arr #(workerid:num)
{
	my $self = shift;
	my $args = shift;
	my $workerid = shift @$args;

	_validate_workerid($workerid);
	_seen_worker($workerid);

	my $sth = $dbh->prepare("SELECT id, command FROM commands WHERE worker = ?");
	my $r = $sth->execute($workerid) or die $dbh->errstr;

	my $commands = $sth->fetchall_arrayref;

	return $commands;
}

sub command_enqueue : Public #(workerid:num, command:str)
{
	my $self = shift;
	my $args = shift;
	my $workerid = shift @$args;
	my $command = shift @$args;

	_validate_workerid($workerid);

	my $sth = $dbh->prepare("INSERT INTO commands (worker, command) VALUES(?, ?)");
	my $rc = $sth->execute($workerid, $command) or die $dbh->error;

	return $dbh->last_insert_id(undef,undef,undef,undef);
}

sub command_dequeue : Public #(workerid:num, id:num)
{
	my $self = shift;
	my $args = shift;
	my $workerid = shift @$args or die "missing workerid parameter\n";
	my $id = shift @$args or die "missing id parameter\n";

	_validate_workerid($workerid);

	my $sth = $dbh->prepare("DELETE FROM commands WHERE id = ? and worker = ?");
	my $r = $sth->execute($id, $workerid);

	return int($r);
}

sub list_commands : Public
{
	my $sth = $dbh->prepare("select * from commands");
	$sth->execute();

	my $commands = [];
	while(my $command = $sth->fetchrow_hashref) {
		push @$commands, $command;
	}
	return $commands;
}


1;
