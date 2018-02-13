package OpenQA::WebAPI::Controller::API::V1::Feature;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Feature

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Feature;

=head1 DESCRIPTION

Implements feature API.

=head1 METHODS

=over 4

=item informed()

Post integer value to save feature tour progress of current user in the database

=back

=cut

sub informed {
    my ($self)  = @_;
    my $user    = $self->current_user;
    my $version = $self->param('version');
    $user->update({feature_version => $version});
}

1;
