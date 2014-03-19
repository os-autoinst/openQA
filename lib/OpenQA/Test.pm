# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Test;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use awstandard;
use Scheduler qw/worker_get/;

sub list {
  my $self = shift;

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

  # TODO: implement match, boring and maxage again

  for my $job (@{Scheduler::list_jobs('state' => 'scheduled,running,done',
				      match => $match,
				      maxage => $maxage, fulldetails => 1)||[]}) {

    if ($job->{state} eq 'running' || $job->{state} eq 'done') {

      my $testdirname = $job->{'settings'}->{'NAME'};
      my $results = test_result($testdirname);
      my $result_stats = test_result_stats($results);
      my $backend = $results->{'backend'}->{'backend'} || '';
      $backend =~ s/^.*:://;

      my $run_stat;
      if ($job->{state} eq 'running') {
        my $running_basepath = running_log($testdirname);
        $run_stat = get_running_modinfo($results);
        $run_stat->{'run_backend'} = 0;
        if(-e "$running_basepath/os-autoinst.pid") {
          my $backpid = file_content("$running_basepath/os-autoinst.pid");
          chomp($backpid);
          $run_stat->{'run_backend'} = (-e "/proc/$backpid"); # kill 0 does not work with www user
        }
      }

      my $settings = {
        job => $job,

        res_ok=>$result_stats->{ok}||0,
        res_unknown=>$result_stats->{unk}||0,
        res_fail=>$result_stats->{fail}||0,
        res_overall=>$results->{overall},
        res_dents=>$results->{dents},
        run_stat=>$run_stat,
        backend => $backend,
      };
      if ($job->{state} eq 'running') {
	      unshift @list, $settings;
      } else {
	      push @list, $settings;
      }
    } else {
      my $settings = {
        job => $job,
      };

      push @slist, $settings;
    }
  }

  $self->stash(slist => \@slist);
  $self->stash(list => \@list);
  $self->stash(ntest => @list + @slist);
  $self->stash(prj => $prj);
  $self->stash(hoursfresh => $hoursfresh);

}

sub show {
  my $self = shift;

  return $self->render_not_found if (!defined $self->param('testid'));

  my $job = Scheduler::job_get($self->param('testid'));

  my $testdirname = $job->{'settings'}->{'NAME'};
  my $testresultdir = openqa::testresultdir($testdirname);

  return $self->render(text => "Invalid path", status => 403) if ($testdirname=~/(?:\.\.)|[^a-zA-Z0-9._+-]/);

  $self->stash(testname => $job->{'name'});
  $self->stash(resultdir => $testresultdir);
  $self->stash(fqfn => $self->stash('resultdir')."/autoinst-log.txt");
  $self->stash(iso => $job->{'settings'}->{'ISO'});

  # FIXME: inherited from the old webUI, should really really really die
  $self->stash(res_css => $res_css);
  $self->stash(res_display => $res_display);

#  return $self->render_not_found unless (-e $self->stash('resultdir'));

  my $results = test_result($testdirname);

  # If it's running
  if ($job->{state} eq 'running') {
    $self->stash(worker => worker_get($job->{'worker_id'}));
    $self->stash(backend_info => $results->{backend});
    $self->render('test/running');
    return;
  }

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
        flags => $module->{'flags'},
        audio => $sound, ocr => $ocr
      });
  }

  # TODO: make better
  my $backlogpath = back_log($testdirname);
  my $diskimg = 0;
  if(-e "$backlogpath/l1") {
    if((stat("$backlogpath/l1"))[12] && !((stat("$backlogpath/l2"))[12])) { # skip raid
      $diskimg = 1;
    }
  }

# details box
#FIXME: get test duration
  my $test_duration = 'FIXME'; # strftime("%H:%M:%S",$job->{t_finished} - $job->{t_started});

# result files box
  my @resultfiles = test_resultfile_list($testdirname);

# uploaded logs box
  my @ulogs = test_uploadlog_list($testdirname);

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

sub uploadlog
{
    my $self = shift;

    my $name = $self->param('filename');
    my $testname = $self->param('testid');

    $self->app->log->debug("upload $name $testname");

    if ($self->req->is_limit_exceeded) {
	return $self->render(message => 'File is too big.', status => 200)
    }

    $testname = sanitize_testname($testname);
    my $upname = $name;
    $upname =~ s#.*/##;
    $upname = sanitize_testname($upname);
    unless ($upname && $testname) {
	$testname ||= '';
	$self->app->log->warn("invalid parameters passed, testname '$testname', upname '$upname'");
	return $self->render(text => "invalid parameters", status => 400);
    }

    # FIXME: check database
    unless (-l join('/', $resultdir, $testname)) {
	$self->app->log->warn("test $testname is not running, refused to upload logs");
	return $self->render(text => "test not running", status => 404);
    }
    $self->app->log->info("$upname $testname");

    my $upload = $self->req->upload('upload');
    if (!$upload) {
	return $self->render(message => 'upload file content missing', status => 400)
    }

    my $dir = join('/', $loguploaddir, $testname);
    if (! -e $dir) {
	mkdir($dir) or die "$!";
    }
    my $file = join('/', $dir, $upname);
    $upload->move_to($file);

    return $self->render(text => "OK: $testname -> $upname\n");
}

1;
