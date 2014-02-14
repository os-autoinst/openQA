package OpenQA::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub create {
    my $self = shift;

    my $iso = $self->param('iso');
    my @tests = split(',', ($self->param('tests') || ''));
    unless ($iso) {
        $self->res->message("Missing iso parameter");
        return $self->rendered(400);
    }
    my $jobs = openqa::distri::generate_jobs($self->app->config, iso => $iso, requested_runs => \@tests);

    # XXX: obviously a hack
    my $pattern = $iso;
    if ($jobs && $pattern =~ s/Build\d.*/Build%/) {
        $self->app->log->debug("Stopping old builds for $pattern");
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
    $self->render(json => {count => $cnt});
}

sub destroy {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_delete($iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_cancel($iso);
    $self->render(json => {result => $res});
}

1;
