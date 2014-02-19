package OpenQA::API::V1::Command;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    $self->render(json => {commands => Scheduler::command_get($workerid)});
}

sub create {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    my $command = $self->param('command');

    $self->render(json => {id => Scheduler::command_enqueue_checked(workerid => $workerid, command => $command)});
}

sub destroy {
    my $self = shift;
    my $workerid = $self->stash('workerid');
    my $id = $self->stash('commandid');

    my $res = Scheduler::command_dequeue(workerid => $workerid, id => $id);
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \($res == 1)});
}

1;
