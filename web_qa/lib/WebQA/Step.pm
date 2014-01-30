package WebQA::Step;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use awstandard;

sub init {
  my $self = shift;

  my $testindex = $self->param('stepid');

  my $results = test_result($self->param('testid'));
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
  }
  $self->stash('tabmode', $tabmode);

  1;
}

# Call to viewimg or viewaudio
sub view {
  my $self = shift;
  return 0 unless $self->init();

  my $testindex = $self->stash('testindex');
  my $module_detail = $self->stash('module')->{'details'}->[$testindex-1];
  if ($module_detail->{'audio'}) {
    $self->viewaudio($module_detail);
  } else {
    $self->viewimg($module_detail);
  }
}

sub edit {
  my $self = shift;

  # Needle editor
}

sub src {
  my $self = shift;
  return 0 unless $self->init();

  my $testid = $self->param('testid');
  my $moduleid = $self->param('moduleid');
  my $running = $self->stash('modinfo')->{'running'};

  my $fqfn = testresultdir("$testid/autoinst-log.txt");
  $fqfn = running_log($testid).'/autoinst-log.txt' if (($running||'') ne "" && -e running_log($testid).'/autoinst-log.txt');
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

sub viewimg {
  my $self = shift;
  my $module_detail = shift;
  my $results = $self->stash('results');

  my $needles = [];
  if ($module_detail->{'needle'}) {
    my $needle = needle_info($module_detail->{'needle'}, $results->{'distribution'});
    push(@$needles, {'name' => $module_detail->{'needle'},
        'image' => $self->url_for('needle_file', distri => $results->{'distribution'}, name => $module_detail->{'needle'}.'.png'),
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
      $needleinfo  = needle_info($needlename, $results->{'distribution'});
      next unless $needleinfo;
      push(@$needles, {'name' => $needlename,
          'image' => $self->url_for('needle_file', distri => $results->{'distribution'}, name => "$needlename.png"),
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

sub viewaudio {
  my $self = shift;
}

1;
