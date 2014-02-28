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

package OpenQA::Step;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use awstandard;
use File::Copy;
use Scheduler;

sub init {
  my $self = shift;

  my $testindex = $self->param('stepid');


  my $job = Scheduler::job_get($self->param('testid'));
  $self->stash('testname', $job->{'name'});
  my $testdirname = $job->{'settings'}->{'NAME'};
  my $results = test_result($testdirname);

  unless ($results) {
    $self->render_not_found;
    return 0;
  }
  $self->stash('results', $results);

  my $module = test_result_module($results->{'testmodules'}, $self->param('moduleid'));
  unless ($module) {
    $self->render_not_found;
    return 0;
  }
  $self->stash('module', $module);
  $self->stash('imglist', $module->{'details'});

  my $modinfo = get_running_modinfo($results);
  $self->stash('modinfo', $modinfo);

  my $tabmode = 'screenshot'; # Default
  if ($testindex > @{$module->{'details'}}) {
    # This means that the module have no details at all
    if ($testindex == 1) {
      if ($self->stash('action') eq 'src') {
        $tabmode = 'onlysrc';
      } else {
        $self->redirect_to('src_step');
        return 0;
      }
      # In this case there are details, we simply run out of range
    } else {
      $self->render_not_found;
      return 0;
    }
  } else {
    my $module_detail = $module->{'details'}->[$testindex-1];
    $tabmode = 'audio' if ($module_detail->{'audio'});
    $self->stash('module_detail', $module_detail);
  }
  $self->stash('tabmode', $tabmode);

  1;
}

# Helper function to generate the needle url, with an optional version
sub needle_url {
  my $self = shift;
  my $distri = shift;
  my $name = shift;
  my $version = shift;

  if (defined($version) && $version) {
    $self->url_for('needle_file', distri => $distri, name => $name)->query(version => $version);
  } else {
    $self->url_for('needle_file', distri => $distri, name => $name);
  }
}

# Call to viewimg or viewaudio
sub view {
  my $self = shift;
  return 0 unless $self->init();

  if ('audio' eq $self->stash('tabmode')) {
    $self->render('step/viewaudio');
  } else {
    $self->viewimg;
  }
}

# Needle editor
sub edit {
  my $self = shift;
  return 0 unless $self->init();

  my $module_detail = $self->stash('module_detail');
  my $imgname = $module_detail->{'screenshot'};
  my $results = $self->stash('results');
  my $job = Scheduler::job_get($self->param('testid'));
  my $testdirname = $job->{'settings'}->{'NAME'};

  # Each object in $needles will contain the name, both the url and the local path
  # of the image and 2 lists of areas: 'area' and 'matches'.
  # The former refers to the original definitions and the later shows the position
  # found (best try) in the actual screenshot.
  # The first element of the needles array is the screenshot itself, with an empty
  # 'areas' (there is no needle associated to the screenshot) and with all matching
  # areas in 'matches'.
  my $needles = [];
  # All tags (from all needles)
  my $tags = [];
  $tags = $module_detail->{'tags'} if ($module_detail->{'tags'});
  if ($module_detail->{'needle'}) {

    # First position: the screenshot with all the matching areas (in result)
    push(@$needles, {'name' => 'screenshot',
        'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
        'imagepath' => "$basedir/$prj/testresults/$testdirname/$imgname",
        'area' => [], 'matches' => [], 'tags' => []});
    for my $tag (@$tags) {
      push(@{$needles->[0]->{'tags'}}, $tag);
    }
    for my $area (@{$module_detail->{'area'}}) {
      push(@{$needles->[0]->{'matches'}},
        {'xpos' => int $area->{'x'}, 'width' => int $area->{'w'},
          'ypos' => int $area->{'y'}, 'height' => int $area->{'h'},
          'type' => 'match'});
    }
    # Second position: the only needle (with the same matches)
    my $needle = needle_info($module_detail->{'needle'}, $results->{'distribution'}, $results->{'version'}||'');
    push(@$needles, {'name' => $module_detail->{'needle'},
        'imageurl' => $self->needle_url($results->{'distribution'}, $module_detail->{'needle'}.'.png',
                        $results->{'version'}),
        'imagepath' => $needle->{'image'}, 'area' => $needle->{'area'},
        'tags' => $needle->{'tags'}, 'matches' => $needles->[0]->{'matches'}});
    for my $t (@{$needle->{'tags'}}) {
      push(@$tags, $t) unless grep(/^$t$/, @$tags);
    }


  } elsif ($module_detail->{'needles'}) {

    # First position: the screenshot
    push(@$needles, {'name' => 'screenshot',
        'imagepath' => "$basedir/$prj/testresults/$testdirname/$imgname",
        'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
        'area' => [], 'matches' => [], 'tags' => []});
    for my $tag (@$tags) {
      push(@{$needles->[0]->{'tags'}}, $tag);
    }
    # Afterwards, all the candidate needles
    my $needleinfo;
    my $needlename;
    my $area;
    # For each candidate we will use theee variables:
    # $needle: needle information from result, in which 'areas' refers to the best matches
    # $needlename: read from the above
    # $needleinfo: actual definition of the needle, with the original areas
    # We also use $area for transforming the match information intro a real area
    for my $needle (@{$module_detail->{'needles'}}) {
      $needlename = $needle->{'name'};
      $needleinfo  = needle_info($needlename, $results->{'distribution'}, $results->{'version'}||'');
      push(@$needles, {'name' => $needlename,
          'imageurl' => $self->needle_url($results->{'distribution'}, "$needlename.png", $results->{'version'}),
          'imagepath' => $needleinfo->{'image'},
          'tags' => $needleinfo->{'tags'},
          'area' => $needleinfo->{'area'}, 'matches' => []});
      for my $match (@{$needle->{'area'}}) {
        $area = {'xpos' => int $match->{'x'}, 'width' => int $match->{'w'},
          'ypos' => int $match->{'y'}, 'height' => int $match->{'h'},
          'type' => 'match'};
        push(@{$needles->[0]->{'matches'}}, $area);
        push(@{$needles->[scalar(@$needles)-1]->{'matches'}}, $area);
      }
      for my $t (@{$needleinfo->{'tags'}}) {
        push(@$tags, $t) unless grep(/^$t$/, @$tags);
      }
    }
  } else {
    # Failing with not a single candidate needle
    push(@$needles, {'name' => 'screenshot',
        'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
        'imagepath' => "$basedir/$prj/testresults/$testdirname/$imgname",
        'area' => [], 'matches' => [], 'tags' => $tags});
  }

  # Default values
  #  - area: matches from best candidate
  #  - tags: tags from the screenshot
  my $default_needle = {};
  my $default_name;
  $default_needle->{'tags'} = $needles->[0]->{'tags'};
  if (scalar(@$needles) > 1) {
    $default_needle->{'area'} = $needles->[1]->{'matches'};
    $default_name = $needles->[1]->{'name'};
  } else {
    $default_needle->{'area'} = [];
    $default_name = $self->param('moduleid');
  }
  $default_name = $default_name."-".time;

  $self->stash('needles', $needles);
  $self->stash('tags', $tags);
  $self->stash('default_needle', $default_needle);
  $self->stash('needlename', $default_name);
}

sub src {
  my $self = shift;
  return 0 unless $self->init();

  my $job = Scheduler::job_get($self->param('testid'));
  my $testdirname = $job->{'settings'}->{'NAME'};
  my $moduleid = $self->param('moduleid');
  my $running = $self->stash('modinfo')->{'running'};

  my $fqfn = testresultdir("$testdirname/autoinst-log.txt");
  $fqfn = running_log($testdirname).'/autoinst-log.txt' if (($running||'') ne "" && -e running_log($testdirname).'/autoinst-log.txt');
  my $scriptpath=log_to_scriptpath($fqfn, $moduleid);
  if(!$scriptpath || !-e $scriptpath) {
    $scriptpath||="";
    return $self->render_not_found;
  }

  my $script=file_content($scriptpath);
  $scriptpath=~s/^.*autoinst\///;

  $self->stash('script', $script);
  $self->stash('scriptpath', $scriptpath);
}

sub save_needle {
  my $self = shift;
  return 0 unless $self->init();

  my $results = $self->stash('results');
  my $job = Scheduler::job_get($self->param('testid'));
  my $testdirname = $job->{'settings'}->{'NAME'};
  my $json = $self->param('json');
	my $imagepath = $self->param('imagepath');
	my $needlename = $self->param('needlename');
	my $needledir = needledir($results->{distribution}, $results->{version});
	my $success = 1;

  my $baseneedle = "$perldir/$needledir/$needlename";
  $self->app->log->warn("*** imagepath is from client! FIXME!!!");
  copy($imagepath, "$baseneedle.png") or $success = 0;
  if ($success) {
    system("optipng", "-quiet", "$baseneedle.png");
    open(J, ">", "$baseneedle.json") or $success = 0;
    if ($success) {
      print J $json;
      close(J);
    }
  }
  if ($success) {
    if ($self->app->config->{global}->{scm}||'' eq 'git') {
      if ($needledir && -d "$perldir/$needledir/.git") {
        my @git = ('git',
          '--git-dir', "$perldir/$needledir/.git",
          '--work-tree', "$perldir/$needledir");
        my @files = ($baseneedle.'.json', $baseneedle.'.png');
        system(@git, 'add', @files);
        system(@git, 'commit', '-q', '-m',
	  # FIXME
          sprintf("%s by %s@%s", $job->{'name'}, $ENV{REMOTE_USER}||'anonymous', $ENV{REMOTE_ADDR}),
          @files);
        if (($self->app->config->{'scm git'}->{'do_push'}||'') eq 'yes') {
          system(@git, 'push', 'origin', 'master');
        }
      } else {
        $self->flash(error => "$needledir is not a git repo");
      }
    }
    $self->flash(info => "Needle $needlename created/updated.");
  } else {
    $self->flash(error => "Error creating/updating needle: $!.");
  }
  $self->redirect_to('edit_step');
}

sub viewimg {
  my $self = shift;
  my $module_detail = $self->stash('module_detail');;
  my $results = $self->stash('results');

  my $needles = [];
  if ($module_detail->{'needle'}) {
    my $needle = needle_info($module_detail->{'needle'}, $results->{'distribution'}, $results->{'version'}||'');
    push(@$needles, {'name' => $module_detail->{'needle'},
        'image' => $self->needle_url($results->{'distribution'}, $module_detail->{'needle'}.'.png', $results->{'version'}),
        'areas' => $needle->{'area'}, 'matches' => []});
    for my $area (@{$module_detail->{'area'}}) {
      push(@{$needles->[0]->{'matches'}},
        {'xpos' => int $area->{'x'}, 'width' => int $area->{'w'},
          'ypos' => int $area->{'y'}, 'height' => int $area->{'h'},
          'type' => $area->{'result'}, 'similarity' => int $area->{'similarity'}});
    }
  } elsif ($module_detail->{'needles'}) {
    my $needlename;
    my $needleinfo;
    for my $needle (@{$module_detail->{'needles'}}) {
      $needlename = $needle->{'name'};
      $needleinfo  = needle_info($needlename, $results->{'distribution'}, $results->{'version'}||'');
      next unless $needleinfo;
      push(@$needles, {'name' => $needlename,
          'image' => $self->needle_url($results->{'distribution'}, "$needlename.png", $results->{'version'}),
          'areas' => $needleinfo->{'area'}, 'matches' => []});
      for my $area (@{$needle->{'area'}}) {
        push(@{$needles->[scalar(@$needles)-1]->{'matches'}},
          {'xpos' => int $area->{'x'}, 'width' => int $area->{'w'},
            'ypos' => int $area->{'y'}, 'height' => int $area->{'h'},
            'type' => $area->{'result'}, 'similarity' => int $area->{'similarity'}});
      }
    }
  }

  $self->stash('screenshot', $module_detail->{'screenshot'});
  $self->stash('needles', $needles);
  $self->stash('img_width', 1024);
  $self->stash('img_height', 768);
  $self->render('step/viewimg');
}

1;
