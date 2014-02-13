package OpenQA::API::V1::Worker;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
    my $self = shift;
    $self->render(json => { workers => Scheduler::list_workers });
}

sub create {
    my $self = shift;
    my $host = $self->param('host');
    my $instance = $self->param('instance');
    my $backend= $self->param('backend');

    my $res = Scheduler::worker_register($host, $instance, $backend);
    $self->render(json => { id => $res} );
}

sub show {
    my $self = shift;
    my $res = Scheduler::worker_get($self->stash('workerid'));
    if ($res) {
        $self->render(json => {worker => $res });
    } else {
        $self->render_not_found;
    }
}

1;
