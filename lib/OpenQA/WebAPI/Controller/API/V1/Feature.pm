package OpenQA::WebAPI::Controller::API::V1::Feature;
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

Post integer value to save feature version of current user in the database

=back

=cut

sub informed {
    my ($self) = @_;
    my $validation = $self->validation;
    $validation->required('version')->num();
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
    $self->current_user->update({feature_version => $validation->param('version')});
    $self->render(text => 'ok');
}

1;
