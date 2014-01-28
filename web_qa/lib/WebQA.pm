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
  # Default route
  $r->get('/')->to('test#list');
}

1;
