package OpenQA::Jsonrpc;

use Data::Dump qw/pp/;
use Mojo::Base 'MojoX::JSON::RPC::Service';

use openqa;
use Scheduler ();

# FIXME: this is ugly, isn't there a better way?
sub new
{
  my $class = shift;
  my $self  = $class->SUPER::new(@_);

  for my $m (qw/
    echo
    list_jobs
    list_workers
    worker_register
    iso_new
    iso_delete
    iso_cancel
    job_grab
    job_set_scheduled
    job_set_done
    job_set_cancel
    job_set_waiting
    job_set_continue
    job_create
    job_set_prio
    job_delete
    job_update_result
    job_restart
    job_cancel
    command_get
    command_enqueue
    command_dequeue
    list_commands
    job_get
    worker_get
  /) {
    my $method = eval qq|*{*$m}{CODE}|;
    $self->register($m, $method, { with_self => 1 });
  }

  return $self;
}

sub echo
{
    my ($self, @params) = @_;
    $self->app->log->debug(pp(\@params));
    return @params;
}

sub list_jobs
{
    my ($self, @params) = @_;

    my %params;
    for my $i (@params) {
	    die "invalid argument: $i\n" unless $i =~ /^([[:alnum:]_]+)=([^\s]+)$/;
	    $params{$1} = $2;
    }

    return Scheduler::list_jobs(%params);
}

sub list_workers
{
    return Scheduler::list_workers;
}

sub worker_register # Num(host, instance, backend)
{
    my ($self, @params) = @_;

    return Scheduler::worker_register(@params);
}

sub iso_new
{
    my ($self, @params) = @_;

    my $iso;

    my @requested_runs;

    # handle given parameters
    for my $arg (@params) {
        if ($arg =~ /\.iso$/) {
            # remove any path info path from iso file name
            ($iso = $arg) =~ s|^.*/||;
        } elsif ($arg =~ /^[[:alnum:]]+$/) {
            push @requested_runs, $arg;
        } else {
            die "invalid parameter $arg";
        }
    }

    die "missing iso parameter" unless $iso;

    my $jobs = openqa::distri::generate_jobs($self->app->config, iso => $iso, requested_runs => \@requested_runs);

    # XXX: obviously a hack
    my $pattern = $iso;
    if ($jobs && $pattern =~ s/Build\d.*/Build%/) {
	Scheduler::iso_cancel_old_builds($pattern);
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
sub iso_delete
{
    my ($self, @params) = @_;

    my $r = Scheduler::job_delete($params[0]);
}


sub iso_cancel
{
    my ($self, @params) = @_;

    # remove any path info path from iso file name
    (my $iso = $params[0]) =~ s|^.*/||;

    Scheduler::job_cancel($iso);
}



=head2
takes worker id and a blocking argument
if I specify the parameters here the get exchanged in order, no idea why
=cut
sub job_grab
{
    my $self = shift;
    my $workerid = shift;
    my $blocking = int(shift || 0);

    my $job = Scheduler::job_grab( workerid => $workerid,
                                   blocking => $blocking );

    return $job;
}

=head2
release job from a worker and put back to scheduled (e.g. if worker aborted)
=cut
sub job_set_scheduled
{
    my ($self, @params) = @_;

    my $r = Scheduler::job_set_scheduled( $params[0] );
    $self->raise_error(code => 400, message => "failed to release job") unless $r == 1;
}

=head2
mark job as done
=cut
sub job_set_done
{
    my $self = shift;
    my $jobid = int(shift);
    my $result = shift;

    my $r = Scheduler::job_set_done( jobid => $jobid, result => $result );
    $self->raise_error(code => 400, message => "failed to finish job") unless $r == 1;
}

=head2
mark job as stopped
=cut
sub job_set_cancel
{
    my ($self, @params) = @_;

    my $r = Scheduler::job_set_cancel( $params[0] );
    $self->raise_error(code => 400, message => "failed to cancel job") unless $r == 1;
}

=head2
mark job as waiting
=cut
sub job_set_waiting
{
    my ($self, @params) = @_;

    my $r = Scheduler::job_set_waiting( $params[0] );
    $self->raise_error(code => 400, message => "failed to set job to waiting") unless $r == 1;
}

=head2
continue job after waiting
=cut
sub job_set_continue
{
    my ($self, @params) = @_;

    my $r = Scheduler::job_set_continue( $params[0] );
    $self->raise_error(code => 400, message => "failed to continue job") unless $r == 1;
}

=head2
create a job, expects key=value pairs
=cut
sub job_create
{
    my ($self, @params) = @_;
    my %settings;
    for my $i (@params) {
        die "invalid argument: $i\n" unless $i =~ /^([A-Z_]+)=([^\s]+)$/;
        $settings{$1} = $2;
    }

    return Scheduler::job_create(%settings);
}

sub job_set_prio
{
    my $self = shift;
    my $id = int(shift);
    my $prio = int(shift);

    my $r = Scheduler::job_set_prio( jobid => $id, prio => $prio );
    $self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

sub job_delete
{
    my ($self, @params) = @_;
    
    my $r = Scheduler::job_delete($params[0]);
    $self->raise_error(code => 400, message => "didn't delete anything") unless $r == 1;
}

sub job_update_result
{
    my $self = shift;
    my $id = int(shift);
    my $result = shift;

    my $r = Scheduler::job_update_result( jobid => $id, result => $result );
    $self->raise_error(code => 400, message => "didn't update anything") unless $r == 1;
}

sub job_restart
{
    my $self = shift;
    my $name = shift or die "missing name parameter\n";

    Scheduler::job_restart($name);
}

sub job_cancel:
{
    my $self = shift;
    my $name = shift or die "missing name parameter\n";

    Scheduler::job_cancel($name);
}

sub command_get
{
    my $self = shift;
    my $workerid = shift;

    return Scheduler::command_get($workerid);
}

sub command_enqueue
{
    my $self = shift;
    my $workerid = shift;
    my $command = shift;

    return Scheduler::command_enqueue( workerid => $workerid, command => $command );
}

sub command_dequeue
{
    my $self = shift;
    my $workerid = shift;
    my $id = shift;

    return Scheduler::command_dequeue( workerid => $workerid, id => $id );
}

sub list_commands
{
    return Scheduler::list_commands;
}

sub job_get
{
    my $self = shift;
    my $jobid = shift;

    return Scheduler::job_get($jobid);
}

sub worker_get
{
    my $self = shift;
    my $workerid = shift;

    return Scheduler::worker_get($workerid);
}

1;


# default for this method is with_svc_obj
#__PACKAGE__->register_rpc_method_names( qw/echo list_jobs/ );

1;
