package WebQA::Schedule;
use Mojo::Base 'Mojolicious::Controller';
use openqa;

sub cancel
{
    my $self = shift;
    my $back = $self->param('back');
    my $name = $self->param('testid');

    $self->stash('back', $back);

    if(!is_authorized_rw()) {
	#return $self->render(text => "forbidden", status => 403);
	$self->stash('denied', 1);
    } else {
        Scheduler::job_stop($name);
	$self->stash('denied', 0);
    }
}

sub restart
{
    my $self = shift;
    my $back = $self->param('back');
    my $name = $self->param('testid');

    $self->stash('back', $back);

    if(!is_authorized_rw()) {
	$self->stash('denied', 1);
    } else {
        Scheduler::job_restart($name);
	$self->stash('denied', 0);
    }
}

sub setpriority
{
    my $self = shift;
    my $back = $self->param('back');
    my $name = $self->param('testid');
    my $priority = $self->param('priority');

    $self->stash('back', $back);

    if(!is_authorized_rw()) {
	$self->stash('denied', 1);
    } else {
        my $job = Scheduler::job_get($name);
        Scheduler::job_set_prio( prio=>$priority, jobid=>$job->{id} );
	$self->stash('denied', 0);
    }
}

1;
