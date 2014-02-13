package OpenQA::API::V1::Job;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;

    my $state = $self->param('state');
    my $finish_after = $self->param('finish_after');
    my $build = $self->param('build');
    $finish_after = "'$finish_after'" if $finish_after; # Add simple quotes to finish_after

    my $res = Scheduler::list_jobs(state => $state, finish_after => $finish_after, build => $build);
    $self->render(json => {jobs => $res});
}

sub create {
    my $self = shift;
    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;

    my $res = Scheduler::job_create(%up_params);
    $self->render(json => {id => $res});
}

sub grab {
    my $self = shift;

    my $workerid = $self->stash('workerid');
    my $blocking = int ($self->param('blocking') || 0);

    my $res = Scheduler::job_grab(workerid => $workerid, blocking => $blocking);
    $self->render(json => {job => $res});
}

sub show {
    my $self = shift;
    my $res = Scheduler::job_get(int($self->stash('jobid')));
    if ($res) {
        $self->render(json => {job => $res});
    } else {
        $self->render_not_found;
    }
}

# set_scheduled set_cancel set_waiting and set_continue
sub set_command {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $command = 'job_set_'.$self->stash('command');

    my $res = eval("Scheduler::$command($jobid)");
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \$res});
}

sub destroy {
    my $self = shift;
    my $res = Scheduler::job_delete(int($self->stash('jobid')));
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub prio {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $prio = int($self->param('prio'));

    my $res = Scheduler::job_set_prio(jobid => $jobid, prio => $prio);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub result {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $result = $self->param('result');

    my $res = Scheduler::job_update_result(jobid => $jobid, result => $result);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub done {
    my $self = shift;
    my $jobid = int($self->stash('jobid'));
    my $result = $self->param('result');

    my $res = Scheduler::job_update_result(jobid => $jobid, result => $result);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

sub restart {
    my $self = shift;
    my $name = $self->param('name');

    my $res = Scheduler::job_restart($name);
    $self->render(json => {result => $res});
}

sub cancel {
    my $self = shift;
    my $name = $self->param('name');

    my $res = Scheduler::job_cancel($name);
    $self->render(json => {result => $res});
}

1;
