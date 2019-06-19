package WebAPIPlugin::Hello;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Base 'Mojolicious::Controller';

sub register {
    my $self = shift;
}

sub hello {
    my $self = shift;
    $self->render(json => {"msg", "HELLO WORLD!!"});
}

1;
