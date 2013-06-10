package Makefile;

use base qw(JSON::RPC::Procedure);

use strict;
use Data::Dump qw/pp/;

use FindBin;
use lib $FindBin::Bin;
use Scheduler ();
use openqa ();

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
                my %settings = ( ISO => $iso,
                                 NAME => join('-', @{$params}{qw(distri version flavor arch build)}, $run),
                                 DISTRI => lc($params->{distri}),
                                 DESKTOP => 'kde' );

                # merge defaults form above with the settings from %testruns
                my $test_definition = $testruns{$run}->{settings};
                @settings{keys %$test_definition} = values %$test_definition;

		## define some default envs

		# match i386, i586, i686 and Biarch-i586-x86_64
		if ($params->{arch} =~ m/i[3-6]86/) {
		  $settings{QEMUCPU} ||= 'qemu32';
		}
		if($params->{flavor} =~ m/Live/i || $params->{flavor} =~ m/Rescue/i) {
		  $settings{LIVECD}=1;
		}
		if ($params->{flavor} =~ m/Promo/i) {
		  $settings{PROMO}=1;
		}
		if($params->{flavor}=~m/(DVD|NET|KDE|GNOME|LXDE|XFCE)/) {
		  $settings{$1}=1;
		  $settings{NETBOOT}=$settings{NET};

		  if($settings{LIVECD}) {
		    $settings{DESKTOP}=lc($1);
		  }
		}

                # create a new job with these parameters and count if successful
                $cnt++ if Scheduler::job_create(%settings)
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

    return Scheduler::job_create(%settings);
}

sub job_set_prio : Public #(id:num, prio:num)
{
    my $self = shift;
    my $args = shift;
    my $id = int(shift $args);
    my $prio = int(shift $args);

    my $r = Scheduler::job_set_prio( jobid => $id, prio => $prio );
    $self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

sub job_delete : Public(id:num)
{
    my $self = shift;
    my $args = shift;
    
    my $r = Scheduler::job_delete($args->{id});
    $self->raise_error(code => 400, message => "didn't delete anything") unless $r == 1;
}

sub job_update_result : Public #(id:num, result)
{
    my $self = shift;
    my $args = shift;
    my $id = int(shift $args);
    my $result = shift $args;

    my $r = Scheduler::job_update_result( jobid => $id, result => $result );
    $self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

sub job_find_by_name : Public #(name:str)
{
    my $self = shift;
    my $args = shift;
    my $name = shift @$args or die "missing name parameter\n";

    return Scheduler::job_find_by_name($name)->[0];
}

sub job_restart_by_name : Public #(name:str)
{
    my $self = shift;
    my $args = shift;
    my $name = shift @$args or die "missing name parameter\n";

    Scheduler::job_restart_by_name($name);
}

sub command_get : Arr #(workerid:num)
{
    my $self = shift;
    my $args = shift;
    my $workerid = shift @$args;

    return Scheduler::command_get($workerid);
}

sub command_enqueue : Public #(workerid:num, command:str)
{
    my $self = shift;
    my $args = shift;
    my $workerid = shift @$args;
    my $command = shift @$args;

    return Scheduler::command_enqueue( workerid => $workerid, command => $command );
}

sub command_dequeue : Public #(workerid:num, id:num)
{
    my $self = shift;
    my $args = shift;
    my $workerid = shift @$args;
    my $id = shift @$args;

    return Scheduler::command_dequeue( workerid => $workerid, id => $id );
}

sub list_commands : Public
{
    return Scheduler::list_commands;
}

1;
