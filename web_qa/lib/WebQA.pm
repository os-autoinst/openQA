package WebQA;
use Mojo::Base 'Mojolicious';
use WebQA::Helpers;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Documentation browser under "/perldoc"
  $self->plugin('PODRenderer');
  $self->plugin('WebQA::Helpers');

  # Router
  my $r = $self->routes;

  $r->get('/tests')->name('tests')->to('test#list');
  my $test_r = $r->get('/tests/#testid');
  $test_r->get('/')->name('test')->to('test#show');
  $test_r->get('/currentstep')->name('currentstep')->to('test#currentstep');
  $test_r->get('/modlist')->name('modlist')->to('test#modlist');
  $test_r->get('/modstat')->name('modstat')->to('test#modstat');
  $test_r->get('/status')->name('status')->to('test#status');
  $test_r->get('/livelog')->name('livelog')->to('test#livelog');
  $test_r->get('/streaming')->name('streaming')->to('streaming#show');
  $test_r->post('/cancel')->name('cancel')->to('schedule#cancel');
  $test_r->post('/restart')->name('restart')->to('schedule#restart');
  $test_r->post('/setpriority/:priority')->name('setpriority')->to('schedule#setpriority');
  $test_r->post('/uploadlog/#filename')->name('uploadlog')->to('test#uploadlog');
  $test_r->get('/images/:filename')->name('test_img')->to('file#test_image');
  $test_r->get('/diskimages/:imageid')->name('diskimage')->to('diskimage#show');

  my $asset_r = $test_r->get('/modules/:moduleid/steps/:stepid');
  $asset_r->get('/view')->name('view_step')->to(action => 'view');
  $asset_r->get('/edit')->name('edit_step')->to(action => 'edit');
  $asset_r->get('/src')->name('src_step')->to(action => 'src');
  $asset_r->get('/')->name('step')->to(controller => 'step', action => 'view', stepid => 1);

  $r->get('/builds/:buildid')->name('build')->to('build#show');
  $r->post('/rpc')->name('rpc')->to('rpc#call');
  $r->post('/jsonrpc/:method')->name('jsonrpc')->to('jsonrpc#call');

  $r->get('/needles/:distri/:name', format => ['png'])->name('needle_img')->to('file#needle_image');
  $r->get('/needles/:distri/:name', format => ['json'])->name('needle_json')->to('file#needle_json');

  # Default route
  $r->get('/')->to('test#list');
}

1;
