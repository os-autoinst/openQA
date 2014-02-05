package WebQA;
use Mojo::Base 'Mojolicious';
use WebQA::Helpers;
use WebQA::Jsonrpc;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Set some application defaults
  $self->defaults( appname => 'openQA' );

  # Documentation browser under "/perldoc"
  $self->plugin('PODRenderer');
  $self->plugin('WebQA::Helpers');

  # Router
  my $r = $self->routes;

  $r->get('/tests')->name('tests')->to('test#list');
  my $test_r = $r->route('/tests/#testid');
  $test_r->get('/')->name('test')->to('test#show');

  $test_r->get('/modlist')->name('modlist')->to('running#modlist');
  $test_r->get('/status')->name('status')->to('running#status');
  $test_r->get('/livelog')->name('livelog')->to('running#livelog');
  $test_r->get('/streaming')->name('streaming')->to('running#streaming');
  $test_r->get('/edit')->name('edit_test')->to('running#edit');

  # FIXME: should be post
  $test_r->get('/cancel')->name('cancel')->to('schedule#cancel');
  $test_r->get('/restart')->name('restart')->to('schedule#restart');
  $test_r->get('/setpriority/:priority')->name('setpriority')->to('schedule#setpriority');
  $test_r->post('/uploadlog/#filename')->name('uploadlog')->to('test#uploadlog');

  $test_r->get('/images/:filename')->name('test_img')->to('file#test_file');
  $test_r->get('/file/:filename')->name('test_file')->to('file#test_file');
  $test_r->get('/logfile/:filename')->name('test_logfile')->to('file#test_logfile');
  $test_r->get('/diskimages/:imageid')->name('diskimage')->to('file#test_diskimage');

  my $asset_r = $test_r->route('/modules/:moduleid/steps/:stepid')->to(controller => 'step');
  $asset_r->get('/view')->to(action => 'view');
  $asset_r->get('/edit')->name('edit_step')->to(action => 'edit');
  $asset_r->get('/src')->name('src_step')->to(action => 'src');
  $asset_r->post('/')->name('save_needle')->to(action => 'save_needle');
  $asset_r->get('/')->name('step')->to(action => 'view');

  $r->get('/builds/:buildid')->name('build')->to('build#show');
  $r->post('/rpc')->name('rpc')->to('rpc#call');
#  $r->post('/jsonrpc/:method')->name('jsonrpc')->to('jsonrpc#call');

  $self->plugin(
    'json_rpc_dispatcher',
    services => {
      '/jsonrpc'  => WebQA::Jsonrpc->new,
    },
    exception_handler => sub {
      my ( $dispatcher, $err, $m ) = @_;

      # $dispatcher is the dispatcher Mojolicious::Controller object
      # $err is $@ received from the exception
      # $m is the MojoX::JSON::RPC::Dispatcher::Method object to be returned.

      $dispatcher->app->log->error(qq{Internal error: $err});

      # Fake invalid request
      $m->invalid_request('Faking invalid request');
      return;
    }
  );


  $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');

  # Favicon
  $r->get('/favicon.ico' => sub {my $c = shift; $c->render_static('favicon.ico') });
  # Default route
  $r->get('/')->name('index')->to('index#index');
}

1;
