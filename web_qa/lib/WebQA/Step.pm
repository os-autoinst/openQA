package WebQA::Step;
use Mojo::Base 'Mojolicious::Controller';
use openqa;

sub view {
  my $self = shift;

  # Call to viewimg or viewaudio

  my $testindex = $self->param('stepid');

  my $results = test_result($self->param('testid'));
  return $self->render_not_found unless ($results);
  $self->stash('results', $results);

  my $module = test_result_module($results->{'testmodules'}, $self->param('moduleid'));
  return $self->render_not_found unless ($module);
  $self->stash('module', $module);

  my $modinfo = get_running_modinfo($results);
  $self->stash('modinfo', $modinfo);

  if ($testindex > @{$module->{'details'}}) {
    # This means that the module have no details at all
    if ($testindex == 1) {
      return $self->render('step/nodetails');
      # In this case there are details, we simply run out of range
    } else {
      return $self->render_not_found;
    }
  }

  my $module_detail = $module->{'details'}->[$testindex-1];
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

  # Old viewsrc
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
  $self->stash('imglist', $self->stash('module')->{'details'});
  $self->stash('needles', $needles);
  $self->stash('img_width', 1024);
  $self->stash('img_height', 768);
  $self->stash('tabmode', 'screenshot');
  $self->render('step/viewimg');
}

sub viewaudio {
  my $self = shift;
}

1;
