package Scheduler;

use strict;
use DBI;
#use List::Util qw/shuffle/;
#use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
use openqa ();

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw(_seen_worker _validate_workerid);
#qw(job_fill_settings list_jobs list_workers _seen_worker _validate_workerid);

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

sub list_jobs {
    my $sth = $dbh->prepare($get_job_stmt);
    $sth->execute();
    
    my $jobs = [];
    while(my $job = $sth->fetchrow_hashref) {
        job_fill_settings($job);
        push @$jobs, $job;
    }
    return $jobs;
}

sub _seen_worker($) {
    my $id = shift;
    my $sth = $dbh->prepare("UPDATE worker SET seen = datetime('now') WHERE id = ?");
    $sth->execute($id) or die "SQL failed\n";
}

sub list_workers {
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
sub worker_register {
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

# TODO: add some sanity check so the same host doesn't grab two jobs
sub job_grab
{
    my %args = @_;
    my $workerid = $args{workerid};
    my $blocking = int($args{blocking} || 0);

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
        last;
    }

    return $job;
}
