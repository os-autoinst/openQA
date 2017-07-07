package OpenQA::WebAPI::Controller::API::V1::Feature;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';

sub informed {
    my ($self)  = @_;
    my $user    = $self->current_user;
    my $version = $self->param('version');
    $user->update({last_login_version => $version});
    my $seen = $self->param('seen');
    $user->update({feature_informed => $seen});
}

sub check {
    my ($self) = @_;
    my $user = $self->current_user;
    $self->respond_to(json => {json => {version => $user->last_login_version, seen => $user->feature_informed}},);
}

1;
