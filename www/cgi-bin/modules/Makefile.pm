package Makefile;

use base qw(JSON::RPC::Procedure);

use strict;
use DBI;
use List::Util qw/shuffle/;
use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
use Scheduler qw(_seen_worker _validate_workerid);
use openqa ();

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

sub echo : Public
{
    print STDERR pp \%ENV;
    return $_[1];
}

sub list_jobs : Public
{
    my $self = shift;
    my $args = shift;

    my %params;
    for my $i (@$args) {
	    die "invalid argument: $i\n" unless $i =~ /^([[:alnum:]_]+)=([^\s]+)$/;
	    $params{$1} = $2;
    }

    return Scheduler::list_jobs(%params);
}

sub list_workers : Public
{
    return Scheduler::list_workers;
}

sub worker_register : Num(host, instance, backend)
{
    my $self = shift;
    my $args = shift;
    
    return Scheduler::worker_register(%$args);
}

sub iso_new : Num(iso)
{
	my $self = shift;
	my $args = shift;

	my %testruns = ( 64 => { applies => sub { $_[0]->{arch} =~ /Biarch/ },
                                 settings => {'QEMUCPU' => 'qemu64'} },
			 RAID0 => { applies => sub {1},
                                    settings => {'RAIDLEVEL' => '0'} },
			 RAID1 => { applies => sub {1},
                                    settings => {'RAIDLEVEL' => '1'} },
			 RAID10 => { applies => sub {1},
                                     settings => {'RAIDLEVEL' => '10'} },
			 RAID5 => { applies => sub {1},
                                    settings => {'RAIDLEVEL' => '5'} },
			 btrfs => { applies => sub {1},
                                    settings => {'BTRFS' => '1'} },
			 btrfscryptlvm => { applies => sub {1},
                                            settings => {'BTRFS' => '1', 'ENCRYPT' => '1', 'LVM' => '1'} },
			 cryptlvm => { applies => sub {1},
                                       settings => {'REBOOTAFTERINSTALL' => '0', 'ENCRYPT' => '1', 'LVM' => '1'} },
			 de => { applies => sub {1},
                                 settings => {'DOCRUN' => '1', 'INSTLANG' => 'de_DE', 'QEMUVGA' => 'std'} },
			 doc => { applies => sub {1},
                                  settings => {'DOCRUN' => '1', 'QEMUVGA' => 'std'} },
			 gnome => { applies => sub {1},
                                    settings => {'DESKTOP' => 'gnome', 'LVM' => '1'} },
			 live => { applies => sub { $_[0]->{flavor} =~ /Live/ },
                                   settings => {'LIVETEST' => '1', 'REBOOTAFTERINSTALL' => '0'} },
			 lxde => { applies => sub { $_[0]->{flavor} !~ /Live/ },
                                   settings => {'DESKTOP' => 'lxde', 'LVM' => '1'} },
                         xfce => { applies => sub { $_[0]->{flavor} !~ /Live/ },
                                   settings => {'DESKTOP' => 'xfce'} },
			 minimalx => { applies => sub { $_[0]->{flavor} !~ /Live/ },
                                       settings => {'DESKTOP' => 'minimalx'} },
			 nice => { applies => sub {1},
                                   settings => {'NICEVIDEO' => '1', 'DOCRUN' => '1', 'REBOOTAFTERINSTALL' => '0', 'SCREENSHOTINTERVAL' => '0.25'} },
			 smp => { applies => sub {1},
                                  settings => {'QEMUCPUS' => '4'} },
			 splitusr => { applies => sub { $_[0]->{flavor} !~ /Live/ },
                                       settings => {'SPLITUSR' => '1'} },
			 textmode => { applies => sub { $_[0]->{flavor} !~ /Live/ },
                                       settings => {'DESKTOP' => 'textmode', 'VIDEOMODE' => 'text'} },
			 uefi => { applies => sub {1},
                                   settings => {'UEFI' => '/openqa/uefi', 'DESKTOP' => 'lxde'} },
			 usbboot => { applies => sub {1},
                                      settings => {'USBBOOT' => '1', 'LIVETEST' => '1'} },
			 usbinst => { applies => sub {1},
                                      settings => {'USBBOOT' => '1'} }
        );
        
        # remove any path info path from iso file name
	(my $iso = $args->{iso}) =~ s|^.*/||;
	my $params = openqa::parse_iso($iso);

        my $cnt = 0;

        # only continue if parsing the ISO filename was successful
	if ( $params ) {
            # go through all the testscenarios defined in %testruns:
            foreach my $run ( keys(%testruns) ) {
                # the testrun applies if the anonlymous 'applies' function returns true
                if ( $testruns{$run}->{applies}->($params) ) {
                    print STDERR "$run applied $iso\n";
                }
                else {
                    print STDERR "$run didn't apply $iso\n";
                    next;
                }

                # set defaults here:
                my %env = ( ISO => $iso,
                            NAME => join('-', @{$params}{qw(distri version flavor arch build)}, $run),
                            DISTRI => lc($params->{distri}),
                            DESKTOP => 'kde' );

                # merge defaults form above with the settings from %testruns
                my $settings = $testruns{$run}->{settings};
                @env{keys %$settings} = values %$settings;

                # convert %env to 'KEY=value' strings
                my @env = map { $_.'='.$env{$_} } keys %env;

                # create a new job with these parameters and count if successful
		$cnt++ if job_create( $self, \@env );
            }

	}

        return $cnt;
}

=head2
takes worker id and a blocking argument
if I specify the parameters here the get exchanged in order, no idea why
=cut
sub job_grab : Num
{
    my $self = shift;
    my $args = shift;
    my $workerid = shift @$args;
    my $blocking = int(shift @$args || 0);

    my $job = Scheduler::job_grab( workerid => $workerid,
                                   blocking => $blocking );

    return $job;
}

=head2
release job from a worker and put back to scheduled (e.g. if worker aborted)
=cut
sub job_release : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_release( $args->{id} );
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

    my $r = Scheduler::job_done( jobid => $jobid, result => $result );
    $self->raise_error(code => 400, message => "failed to finish job") unless $r == 1;
}

=head2
mark job as stopped
=cut
sub job_stop : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_stop( $args->{id} );
    $self->raise_error(code => 400, message => "failed to stop job") unless $r == 1;
}

=head2
mark job as waiting
=cut
sub job_waiting : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_waiting( $args->{id} );
    $self->raise_error(code => 400, message => "failed to set job to waiting") unless $r == 1;
}

=head2
continue job after waiting
=cut
sub job_continue : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_continue( $args->{id} );
    $self->raise_error(code => 400, message => "failed to continue job") unless $r == 1;
}

## REFACTORING MARKER: unexpored area begins here ##

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


sub _job_find_by_name($;@)
{
	my $name = shift;
	my @cols = @_;
	@cols = ('id') unless @_;
	
	my $sth = $dbh->prepare("SELECT ".join(',', @cols)." FROM jobs WHERE name = ?");
	my $rc = $sth->execute($name);
	my $row = $sth->fetchrow_arrayref;

	return $row||[undef];
}

sub job_find_by_name : Public #(name:str)
{
	my $self = shift;
	my $args = shift;
	my $name = shift @$args or die "missing name parameter\n";

	return _job_find_by_name($name)->[0];
}

sub job_restart_by_name : Public #(name:str)
{
	my $self = shift;
	my $args = shift;
	my $name = shift @$args or die "missing name parameter\n";


	# needs to be a transaction as we need to make sure no worker assigns
	# itself while we modify the job
	$dbh->begin_work;
	eval {
		my ($id, $workerid) = @{_job_find_by_name($name, 'id', 'worker')};

		print STDERR "workerid $id, $workerid\n";
		if ($workerid) {
			my $sth = $dbh->prepare("INSERT INTO commands (worker, command) VALUES(?, ?)");
			my $rc = $sth->execute($workerid, "abort") or die $dbh->error;
		} else {
			my $state = "(select id from job_state where name = 'scheduled' limit 1)";
			my $sth = $dbh->prepare("UPDATE jobs set state = $state, worker = 0, start_date = NULL, finish_date = NULL, result = NULL WHERE id = ?");
			my $r = $sth->execute($id) or die $dbh->errstr;

		}
		$dbh->commit;
	};
	if ($@) {
		print STDERR "$@\n";
		eval { $dbh->rollback };
		next;
	}
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
