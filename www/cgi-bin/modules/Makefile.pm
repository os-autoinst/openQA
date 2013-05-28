package Makefile;

use base qw(JSON::RPC::Procedure);

use strict;
use DBI;
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
	while(my $row = $sth->fetchrow_hashref) {
		push @$jobs, $row;
	}
	return $jobs;
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

sub job_set_prio : Bool(id:num, prio:num)
{
	my $self = shift;
	my $args = shift;
	my $id = int($args->{id});
	my $prio = int($args->{prio});
	my $sth = $dbh->prepare("UPDATE jobs SET priority = ? where id = ?");
	$sth->execute($id, $prio) or return 0;
	return 1;
}

sub job_delete : Bool(id:num)
{
	my $self = shift;
	my $args = shift;
	my $id = int($args->{id});
	$dbh->begin_work;
	eval {
		my $sth = $dbh->prepare("DELETE FROM job_settings WHERE jobid = ?");
		$sth->execute($id);
		$sth = $dbh->prepare("DELETE FROM jobs WHERE id = ?");
		$sth->execute($id);
		$dbh->commit;
	};
	if ($@) {
		print STDERR "$@\n";
		eval { $dbh->rollback };
	}
	return 1;
}

1;
