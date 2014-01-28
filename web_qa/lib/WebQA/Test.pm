package WebQA::Test;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub list {
  my $self = shift;

  require boring if $self->param('ib');
  my $match;
  if(defined($self->param('match'))) {
    $match = $self->param('match');
	  $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g; # sanitize
  }

  my $defaulthoursfresh=4*24;
  if (!defined($self->param('hours')) || $self->param('hours') =~ m/\D/) {
    $self->param(hours => $defaulthoursfresh);
  }
  my $hoursfresh = $self->param('hours') + 0;
  if ($hoursfresh < 1 || $hoursfresh > 900) {
    $hoursfresh=$defaulthoursfresh
  }
  my $maxage = 3600 * $hoursfresh;
  
  my @slist=();
  my @list=();
  my $now=time();
  
  # schedule list
  for my $job (@{Scheduler::list_jobs('state' => 'scheduled,stopped')||[]}) {
    my $testname = $job->{'name'};
    next if($match && $testname !~ m/$match/);
    my $params = openqa::parse_testname($testname);
    push(@slist, {
        priority => $job->{priority},
        state => $job->{'state'},
        testname=>$testname, distri=>$params->{distri}.'-'.$params->{version}, type=>$params->{flavor}, arch=>$params->{arch},
        build=>$params->{build}, extrainfo=>$params->{extrainfo}, mtime=>0
      }
    );
  }
  # schedule list end

  for my $r (<$resultdir/*>) {
    next unless -d $r;
    my @s;
    if(-e "$r/autoinst-log.txt") {@s = stat("$r/autoinst-log.txt");}
    else {@s = stat($r);} # running test don't have a logfile, yet
    my $mtime = $s[9];
    next if $mtime < $now - $maxage; # skip old
    next if($match && $r!~m/$match/);
    my $testname = path_to_testname($r);
    my $params = openqa::parse_testname($testname);

    my $run_stat = {};

    my $results = test_result($testname);

    my $result_stats = test_result_stats($results);
    my $result = test_result_hash($results);

    my $running = 0;
    if(not -e "$r/autoinst-log.txt") {
      # running
      my $running_basepath = running_log($testname);
      $run_stat = get_running_modinfo($results);
      $run_stat->{'run_backend'} = 0;
      if(-e "$running_basepath/os-autoinst.pid") {
        my $backpid = file_content("$running_basepath/os-autoinst.pid");
        chomp($backpid);
        $run_stat->{'run_backend'} = (-e "/proc/$backpid"); # kill 0 does not work with www user
      }
      $running = 1;
    } else {
      $mtime = (stat(_))[9];
    }
    my $backend = $results->{'backend'}->{'backend'} || '';
    $backend =~s/^.*:://;
    if($self->param('ib')) {
      next if(boring::is_boring($r, $result));
    }
    if($self->param('ob')) {
      next if($self->param('ob') ne "" and $self->param('ob') ne $backend);
    }
    push(@list, {
        testname=>$testname, running=>$running, distri=>$params->{distri}.'-'.$params->{version},
        type=>$params->{flavor}, arch=>$params->{arch},
        build=>$params->{build}, extrainfo=>$params->{extrainfo}, mtime=>$mtime, backend => $backend,
        res_ok=>$result_stats->{ok}||0, res_unknown=>$result_stats->{unk}||0, res_fail=>$result_stats->{fail}||0,
        res_overall=>$results->{overall}, res_dents=>$results->{dents}, run_stat=>$run_stat
      });
  }

  $self->stash(slist => \@slist);
  $self->stash(list => \@list);
  $self->stash(hoursfresh => $hoursfresh);

}

1;
