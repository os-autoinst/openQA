package OpenQA::API::V1::Authenticate;
use Mojo::Base 'Mojolicious::Controller';

sub authenticate {
    my $self = shift;

    $self->respond_to(json => { json => { token => $self->csrf_token } });
}

1;
