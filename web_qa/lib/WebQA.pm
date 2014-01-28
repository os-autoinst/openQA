package WebQA;
use Mojo::Base 'Mojolicious';

# This method will run once at server start
sub startup {
  my $self = shift;

  # Documentation browser under "/perldoc"
  $self->plugin('PODRenderer');

  # Router
  my $r = $self->routes;

  $r->get('/tests')->name('tests')->to('test#list');
  my $test_r = $r->get('/tests/#testid');
  $test_r->get('/')->name('test')->to('test#show');

  my $asset_r = $test_r->get('/modules/:moduleid/assets/:assetid');
  $asset_r->get('/view')->to(action => 'view');
  $asset_r->get('/edit')->name('edit_asset')->to(action => 'edit');
  $asset_r->get('/src')->name('src_asset')->to(action => 'src');
  $asset_r->get('/')->name('asset')->to(controller => 'asset', action => 'view', assetid => 1);

  # Default route
  $r->get('/')->to('test#list');
}

1;
