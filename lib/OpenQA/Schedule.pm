package OpenQA::Schedule;
use Mojo::Base 'Mojolicious::Controller';
use openqa;

sub _stash_back
{
    my $self = shift;
    my $back = $self->param('back');

    if ($back eq 'results') {
        $back = $self->url_for('tests');
    } elsif ($back eq 'details') {
        $back = $self->url_for('test', 'testid' => $self->param('testid'));
    } else {
        $back = $self->req->headers->referrer;
    }
    $self->stash('back', $back);
}

sub cancel
{
    my $self = shift;
    my $name = $self->param('testid');

    if(!is_authorized_rw()) {
        #return $self->render(text => "forbidden", status => 403);
        $self->stash('denied', 1);
    } else {
        Scheduler::job_stop($name);
        $self->stash('denied', 0);
    }

    _stash_back($self);
}

sub restart
{
    my $self = shift;
    my $name = $self->param('testid');

    if(!is_authorized_rw()) {
        $self->stash('denied', 1);
    } else {
        Scheduler::job_restart($name);
        $self->stash('denied', 0);
    }

    _stash_back($self);
}

sub setpriority
{
    my $self = shift;
    my $name = $self->param('testid');
    my $priority = $self->param('priority');

    if(!is_authorized_rw()) {
        $self->stash('denied', 1);
    } else {
        my $job = Scheduler::job_get($name);
        Scheduler::job_set_prio( prio=>$priority, jobid=>$job->{id} );
        $self->stash('denied', 0);
    }

    _stash_back($self);
}

1;
