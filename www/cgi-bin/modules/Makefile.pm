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

sub worker_register : Public # Num(host, instance, backend)
{
    my $self = shift;
    my $args = shift;
    
    return Scheduler::worker_register(@$args);
}

sub iso_new : Num
{
    my $self = shift;
    my $args = shift;
    my $iso;

    ### definition of special tests
    my %testruns = (
        64 => {
            applies => '$iso{arch} =~ /Biarch/',
            settings => {'QEMUCPU' => 'qemu64'} },
        kde => {
            applies => '$iso{flavor} !~ /GNOME/',
            settings => { 'DESKTOP' => 'kde' },
            prio => 45 },
        gnome => {
            applies => sub { $_[0]->{flavor} !~ /KDE/ },
            settings => {'DESKTOP' => 'gnome', 'LVM' => '1'},
            prio => 45 },
        gnomeLaptop => {
            applies => sub { $_[0]->{flavor} !~ /KDE/ },
            settings => {'DESKTOP' => 'gnome', 'LAPTOP' => '1'},
            prio => 50 },
        kdeLaptop => {
            applies => sub { $_[0]->{flavor} !~ /GNOME/ },
            settings => {'DESKTOP' => 'kde', 'LAPTOP' => '1'},
            prio => 50 },
        lxde => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {'DESKTOP' => 'lxde',
                         'LVM' => '1'},
            prio => 45 },
        xfce => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {'DESKTOP' => 'xfce'},
            prio => 45 },
        minimalx => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {'DESKTOP' => 'minimalx'},
            prio => 45 },
        "minimalx+btrfs" => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {
                    'DESKTOP' => 'minimalx',
                    'BTRFS' => '1'
                    },
            },
        textmode => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {'DESKTOP' => 'textmode',
                         'VIDEOMODE' => 'text'},
            prio => 40 },
        'textmode+btrfs' => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {
                    'DESKTOP' => 'textmode',
                    'BTRFS' => '1',
                    'VIDEOMODE' => 'text'
                    },
            },
        RAID0 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'RAIDLEVEL' => '0',
                    'NICEVIDEO' => '1',
            } },
        RAID1 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'RAIDLEVEL' => '1',
                    'NICEVIDEO' => '1',
            } },
        RAID5 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'RAIDLEVEL' => '5',
                    'NICEVIDEO' => '1',
            } },
        RAID10 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'RAIDLEVEL' => '10',
                    'NICEVIDEO' => '1',
            } },
        btrfs => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'BTRFS' => '1',
                    'NICEVIDEO' => '1',
            } },
        btrfscryptlvm => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {'BTRFS' => '1',
                         'ENCRYPT' => '1',
                         'LVM' => '1',
                         'NICEVIDEO' => '1',
                 } },
        cryptlvm => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {'REBOOTAFTERINSTALL' => '0',
                         'ENCRYPT' => '1',
                         'LVM' => '1',
                         'NICEVIDEO' => '1',
                 } },
        doc_de => {
            applies => 0,
            settings => {'DOCRUN' => '1',
                         'INSTLANG' => 'de_DE',
                         'QEMUVGA' => 'std'} },
        doc => { 
            applies => sub { $_[0]->{flavor} =~ /DVD/ && $_[0]->{arch} =~ /x86_64/ },
            settings => {'DOCRUN' => '1',
                         'QEMUVGA' => 'std'} },
        live => {
            applies => sub { $_[0]->{flavor} =~ /Live/ },
            settings => {'LIVETEST' => '1',
                         'REBOOTAFTERINSTALL' => '0'} },
        rescue => {
            applies => sub { $_[0]->{flavor} =~ /Rescue/ },
            settings => {'DESKTOP' => 'xfce',
                         'LIVETEST' => '1',
                         'REBOOTAFTERINSTALL' => '0'} },
        nice => { 
            applies => sub { $_[0]->{flavor} =~ /DVD/ && $_[0]->{arch} =~ /x86_64/ },
            settings => {'NICEVIDEO' => '1',
                         'DOCRUN' => '1',
                         'REBOOTAFTERINSTALL' => '0',
                         'SCREENSHOTINTERVAL' => '0.25'} },
        smp => { 
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                'QEMUCPUS' => '4',
                'NICEVIDEO' => '1',
            } },
        splitusr => {
            applies => sub { $_[0]->{flavor} =~ /DVD/ && $_[0]->{arch} =~ /x86_64/ },
            settings => {
                'SPLITUSR' => '1',
                'NICEVIDEO' => '1',
            } },
        uefi => { 
            applies => sub { $_[0]->{arch} =~ /x86_64/ },
            settings => {
                'QEMUCPU' => 'qemu64',
                'UEFI' => '1',
                'DESKTOP' => 'lxde',
                'NICEVIDEO' => '1',
            } },
        usbboot => {
            applies => sub { $_[0]->{flavor} =~ /Live/ },
            settings => {'USBBOOT' => '1', 'LIVETEST' => '1'} },
        usbboot_uefi => {
            applies => sub { $_[0]->{flavor} =~ /Live/ && $_[0]->{arch} =~ /x86_64/  },
            settings => {'USBBOOT' => '1',
			 'LIVETEST' => '1',
			 'UEFI' => '1',
                         'QEMUCPU' => 'qemu64',
                     } },
        usbinst => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {'USBBOOT' => '1'} }
        );

    my @requested_runs;

    # handle given parameters
    for my $arg (@$args) {
        if ($arg =~ /\.iso$/) {
            # remove any path info path from iso file name
            ($iso = $arg) =~ s|^.*/||;
        } elsif (exists $testruns{$arg}) {
            push @requested_runs, $arg;
        } else {
            die "invalid parameter $arg";
        }
    }

    # parse the iso filename
    my $params = openqa::parse_iso($iso);
    die "can't parse iso file name" unless $params;
    
    ### iso-based test restrictions go here
    # Rescue_CD cannot be installed; so livetest only
    if($params->{flavor} =~ m/Rescue/i) {
        @requested_runs = ( 'rescue' );
    }

    my $pattern = $iso;
    if ($pattern =~ s/Build\d.*/Build%/) {
	Scheduler::iso_stop_old_builds($pattern);
    }
 
    my $cnt = 0;

    # only continue if parsing the ISO filename was successful
    if ( $params ) {
        # go through all requested special tests or all of them if nothing requested
        foreach my $run ( @requested_runs ? @requested_runs : keys(%testruns) ) {
            # ...->{applies} can be a function ref to be executed, a string to be eval'ed or
            # can even not exist.
            # if it results to true or does not exist the test is assumed to apply
            my $applies = 0;
            if ( defined $testruns{$run}->{applies} ) {
                if ( ref($testruns{$run}->{applies}) eq 'CODE' ) {
                    $applies = $testruns{$run}->{applies}->($params);
                } else {
                    my %iso = %$params;
                    $applies = eval $testruns{$run}->{applies};
                    warn "error in testrun '$run': $@" if $@;
                }
            } else {
                $applies = 1;
            }

            # som debug output
            if ( $applies ) {
                print STDERR "$run applied $iso\n";
            } else {
                print STDERR "$run didn't apply $iso\n";
                next;
            }

            # set defaults here:
            my %settings = ( ISO => $iso,
                             NAME => join('-', @{$params}{qw(distri version flavor arch build)}, $run),
                             DISTRI => lc($params->{distri}),
                             DESKTOP => 'kde' );

            if ($ENV{OPENQA_SUSE_MIRROR}) {
                my $repodir = $iso;
                $repodir =~ s/-Media\.iso$//;
                $repodir .= '-oss';
                $settings{SUSEMIRROR} = $ENV{OPENQA_SUSE_MIRROR}."/iso/$repodir";
                $settings{FULLURL} = 1;
            }

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
                $settings{NOIMAGES}=1;
            }
            if($params->{flavor}=~m/(DVD|NET|KDE|GNOME|LXDE|XFCE)/) {
                $settings{$1}=1;
                $settings{NETBOOT}=$settings{NET} if exists $settings{NET};

                if($settings{LIVECD}) {
		    $settings{DESKTOP}=lc($1);
                }
            }

            # default priority
            my $prio = 50;
            
            # change prio if defined
            $prio = $testruns{$run}->{prio} if ($testruns{$run}->{prio});

            # prefer DVDs
            $prio -= 5 if($params->{flavor}=~m/DVD/);

	    # prefer staging even more
            $prio -= 10 if($params->{flavor}=~m/staging_/);

            # create a new job with these parameters and count if successful
            my $id = Scheduler::job_create(%settings);
            if ($id) {
                $cnt++;

                # change prio only if other than defalt prio
                if( $prio != 50 ) {
                    Scheduler::job_set_prio(jobid => $id, prio => $prio);
                }
            }
        }

    }

    return $cnt;
}


# FIXME: this function is bad, it should do the db query properly
# and handle jobs assigned to workers
sub iso_delete : Num(iso)
{
    my $self = shift;
    my $args = shift;

    # remove any path info path from iso file name
    (my $iso = $args->{iso}) =~ s|^.*/||;

    my $jobs = list_jobs;
    foreach my $job (@$jobs) {
	if ($job->{settings}->{ISO} eq $iso) {
	    Scheduler::job_delete($job->{id});
	}
    }
}


sub iso_stop : Num(iso)
{
    my $self = shift;
    my $args = shift;

    # remove any path info path from iso file name
    (my $iso = $args->{iso}) =~ s|^.*/||;

    Scheduler::job_stop($iso);
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
sub job_set_scheduled : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_set_scheduled( $args->{id} );
    $self->raise_error(code => 400, message => "failed to release job") unless $r == 1;
}

=head2
mark job as done
=cut
sub job_set_done : Public #(id:num, result)
{
    my $self = shift;
    my $args = shift;
    my $jobid = int(shift $args);
    my $result = shift $args;

    my $r = Scheduler::job_set_done( jobid => $jobid, result => $result );
    $self->raise_error(code => 400, message => "failed to finish job") unless $r == 1;
}

=head2
mark job as stopped
=cut
sub job_set_stop : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_set_stop( $args->{id} );
    $self->raise_error(code => 400, message => "failed to stop job") unless $r == 1;
}

=head2
mark job as waiting
=cut
sub job_set_waiting : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_set_waiting( $args->{id} );
    $self->raise_error(code => 400, message => "failed to set job to waiting") unless $r == 1;
}

=head2
continue job after waiting
=cut
sub job_set_continue : Public(id:num)
{
    my $self = shift;
    my $args = shift;

    my $r = Scheduler::job_set_continue( $args->{id} );
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
        die "invalid argument: $i\n" unless $i =~ /^([A-Z_]+)=([^\s]+)$/;
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

sub job_restart: Public #(name:str)
{
    my $self = shift;
    my $args = shift;
    my $name = shift @$args or die "missing name parameter\n";

    Scheduler::job_restart($name);
}

sub job_stop: Public #(name:str)
{
    my $self = shift;
    my $args = shift;
    my $name = shift @$args or die "missing name parameter\n";

    Scheduler::job_stop($name);
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

sub job_get : Public #(jobid)
{
    my $self = shift;
    my $args = shift;
    my $jobid = shift @$args;

    return Scheduler::job_get($jobid);
}

sub worker_get : Public #(workerid)
{
    my $self = shift;
    my $args = shift;
    my $workerid = shift @$args;

    return Scheduler::worker_get($workerid);
}

1;
