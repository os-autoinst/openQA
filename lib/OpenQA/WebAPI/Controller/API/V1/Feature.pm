package OpenQA::WebAPI::Controller::API::V1::Feature;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';

sub informed {
    my ($self)  = @_;
    my $user    = $self->current_user;
    my $version = $self->param('version');
    $user->update({feature_version => $version});
}

sub check {
    my ($self) = @_;
    my $user = $self->current_user;
    return $self->render(json => {version => $user->feature_version});
}

1;
