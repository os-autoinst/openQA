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
  for my $job (@{Scheduler::list_jobs('state' => 'scheduled')||[]}) {
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
  $self->stash(prj => $prj);
  $self->stash(hoursfresh => $hoursfresh);

}

sub show {
  my $self = shift;

  return $self->render_not_found if (!defined $self->param('testid'));
  my $testname = $self->param('testid');
  $testname=~s%^/%%;
  return $self->render(text => "Invalid path", status => 403) if ($testname=~/(?:\.\.)|[^a-zA-Z0-9._+-]/);
  $testname =~ s/\.autoinst\.txt$//; $testname=~s/\.ogv$//; # be tolerant in what we accept
  $self->stash(testname => $testname);
  $self->stash(resultdir => openqa::testresultdir($testname));
  $self->stash(fqfn => $self->stash('resultdir')."/autoinst-log.txt");

  # FIXME: inherited from the old webUI, should really really really die
  $self->stash(res_css => $res_css);
  $self->stash(res_display => $res_display);

  if (!-e $self->stash('fqfn')) {
    running($self);
  } else {
    result($self);
  }
}

sub result {
  my $self = shift;
  my $testname = $self->stash('testname');
  my $testresultdir = $self->stash('resultdir');
  my $results = test_result($testname);

  my @modlist=();
  foreach my $module (@{$results->{'testmodules'}}) {
    my $name = $module->{'name'};
    # add link to $testresultdir/$name*.png via png CGI
    my @imglist;
    my @wavlist;
    my $num = 1;
    foreach my $img (@{$module->{'details'}}) {
      if( $img->{'screenshot'} ) {
        push(@imglist, {name => $img->{'screenshot'}, num => $num++, result => $img->{'result'}});
      }
      elsif( $img->{'audio'} ) {
        push(@wavlist, {name => $img->{'audio'}, num => $num++, result => $img->{'result'}});
      }
    }

#FIXME: Read ocr also from results.json as soon as we know how it looks like

    # add link to $testresultdir/$name*.txt as direct link
    my @ocrlist;
    foreach my $ocrpath (<$testresultdir/$name-[0-9]*.txt>) {
      $ocrpath = data_name($ocrpath);
      my $ocrscreenshotid = $ocrpath;
      $ocrscreenshotid=~s/^\w+-(\d+)/$1/;
      my $ocrres = $module->{'screenshots'}->[--$ocrscreenshotid]->{'ocr_result'} || 'na';
      push(@ocrlist, {name => $ocrpath, result => $ocrres});
    }

    my $sound = (get_testwavs($module->{'name'}))?1:0;
    my $ocr = (@ocrlist)?1:0;
    push(@modlist, {
        name => $module->{'name'},
        result => $module->{'result'},
        screenshots => \@imglist, wavs => \@wavlist, ocrs => \@ocrlist,
        attention => (($module->{'flags'}->{'important'}||0) && ($module->{'result'}||'') ne 'ok')?1:0,
        refimg => 0, audio => $sound, ocr => $ocr
      });
  }

  my $backlogpath = back_log($testname);
  my $diskimg = 0;
  if(-e "$backlogpath/l1") {
    if((stat("$backlogpath/l1"))[12] && !((stat("$backlogpath/l2"))[12])) { # skip raid
      $diskimg = 1;
    }
  }

# details box
#FIXME: get test duration
#my $test_duration = strftime("%H:%M:%S", gmtime(test_duration($testname)));
  my $test_duration = 'n/a';

# result files box
  my @resultfiles = test_resultfile_list($testname);

# uploaded logs box
  my @ulogs = test_uploadlog_list($testname);

  my $job = Scheduler::job_get($testname);

  $self->stash(overall => $results->{'overall'});
  $self->stash(modlist => \@modlist);
  $self->stash(diskimg => $diskimg);
  $self->stash(backend_info => $results->{backend});
  $self->stash(resultfiles => \@resultfiles);
  $self->stash(ulogs => \@ulogs);
  $self->stash(test_duration => $test_duration);
  $self->stash(job => $job);

  $self->render('test/result');
}

sub running {
  my $self = shift;

  $self->app->log->debug('<<<<<<<<<<<<<<<< Running');
}

1;
