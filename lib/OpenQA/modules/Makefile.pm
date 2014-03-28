# Copyright (C) 2014 SUSE Linux Products GmbH
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

package Makefile;

use strict;
use Data::Dump qw/pp/;
use Clone qw/clone/;

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

    my @requested_runs;

    # handle given parameters
    for my $arg (@$args) {
        if ($arg =~ /\.iso$/) {
            # remove any path info path from iso file name
            ($iso = $arg) =~ s|^.*/||;
        } elsif ($arg =~ /^[[:alnum:]]+$/) {
            push @requested_runs, $arg;
        } else {
            die "invalid parameter $arg";
        }
    }

    my $jobs = openqa::distri::generate_jobs(iso => $iso, requested_runs => \@requested_runs);

    # XXX: obviously a hack
    my $pattern = $iso;
    if ($jobs && $pattern =~ s/Build\d.*/Build%/) {
	Scheduler::iso_stop_old_builds($pattern);
    }

    my $cnt = 0;
    for my $settings (@{$jobs||[]}) {
	my $prio = $settings->{PRIO};
	delete $settings->{PRIO};
	# create a new job with these parameters and count if successful
	my $id = Scheduler::job_create(%$settings);
	if ($id) {
	    $cnt++;

	    # change prio only if other than defalt prio
	    if( $prio && $prio != 50 ) {
		Scheduler::job_set_prio(jobid => $id, prio => $prio);
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

    my $r = Scheduler::job_delete($args->{iso});
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
# vim: set ts=4 sw=4 sts=4 et:
