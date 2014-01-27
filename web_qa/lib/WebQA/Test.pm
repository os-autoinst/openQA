package WebQA::Test;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();


# This action will render a template
sub list {
  my $self = shift;
  
  my @slist=();
  
  for my $job (@{Scheduler::list_jobs('state' => 'scheduled,stopped')||[]}) {
    my $testname = $job->{'name'};
    #next if($options{match} && $testname !~ m/$options{match}/);
    my $params = openqa::parse_testname($testname);
    push(@slist, {
        priority => $job->{priority},
        state => $job->{'state'},
        testname=>$testname, distri=>$params->{distri}.'-'.$params->{version}, type=>$params->{flavor}, arch=>$params->{arch},
        build=>$params->{build}, extrainfo=>$params->{extrainfo}, mtime=>0
      }
    );
  }
  $self->stash(slist => \@slist);
}

1;
