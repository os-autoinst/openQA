package OpenQA::WebAPI::Command::gru;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Pg;
use Minion::Command::minion::job;
use OpenQA::Utils 'log_error';

has usage       => "usage: $0 gru [-o]\n";
has description => 'Run a gru to process jobs - give -o to exit _o_nce everything is done';
has job         => sub { Minion::Command::minion::job->new(app => shift->app) };

sub delete_gru {
    my ($self, $id) = @_;
    my $gru = $self->app->db->resultset('GruTasks')->find($id);
    $gru->delete() if $gru;
}

sub fail_gru {
    my ($self, $id, $reason) = @_;
    my $gru = $self->app->db->resultset('GruTasks')->find($id);
    $gru->fail($reason) if $gru;
}

sub cmd_list { shift->job->run(@_) }

sub execute_job {
    my ($self, $job) = @_;

    my $ttl       = $job->info->{notes}{ttl};
    my $elapsed   = time - $job->info->{created};
    my $ttl_error = 'TTL Expired';

    return
      exists $job->info->{notes}{gru_id}
      ? $job->fail({error => $ttl_error}) && $self->fail_gru($job->info->{notes}{gru_id} => $ttl_error)
      : $job->fail({error => $ttl_error})
      if (defined $ttl && $elapsed > $ttl);

    my $buffer;
    my $err;
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        local *STDOUT = $handle;
        $err = $job->execute;
    };

    if (defined $err) {
        log_error("Gru command issue: $err");
        $self->fail_gru($job->info->{notes}{gru_id} => $err)
          if $job->fail({(output => $buffer) x !!(defined $buffer), error => $err})
          && exists $job->info->{notes}{gru_id};
    }
    else {
        $job->finish(defined $buffer ? $buffer : 'Job successfully executed');
        $self->delete_gru($job->info->{notes}{gru_id}) if exists $job->info->{notes}{gru_id};
    }

}

sub cmd_run {
    my $self = shift;
    my $opt  = $_[0] || '';

    my $worker = $self->app->minion->repair->worker->register;

    if ($opt eq '-o') {
        while (my $job = $worker->register->dequeue(0)) {
            $self->execute_job($job);
        }
        return $worker->unregister;
    }

    while (1) {
        next unless my $job = $worker->register->dequeue(5);
        $self->execute_job($job);
    }
    $worker->unregister;
}

sub run {
    # only fetch first 2 args
    my $self = shift;
    my $cmd  = shift;

    if (!$cmd) {
        print "gru: [list|run]\n";
        return;
    }
    if ($cmd eq 'list') {
        $self->cmd_list(@_);
        return;
    }
    if ($cmd eq 'run') {
        $self->cmd_run(@_);
        return;
    }
}

1;
