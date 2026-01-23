# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime::Format::Pg;
use Feature::Compat::Try;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::User

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::User;

=head1 DESCRIPTION

Implements User API.

=head1 METHODS

=over 4

=item delete()

Deletes an existing user.

=back

=cut

sub delete ($self) {
    my $user = $self->schema->resultset('Users')->find($self->param('id'));
    return $self->render(json => {error => 'Not found'}, status => 404) unless $user;
    my $result = $user->delete();
    $self->emit_event('openqa_user_deleted', {username => $user->username});
    $self->render(json => {result => $result});
}

=over 4

=item create_api_key()

Create a new API key.

=back

=cut

sub create_api_key ($self) {
    my $user = $self->current_user;
    my $expiration;
    my $validation = $self->validation;
    $validation->optional('expiration', 'seconds_optional')->datetime;
    return $self->render(
        json => {error => 'Date must be in format ' . DateTime::Format::Pg->format_datetime(DateTime->now())},
        status => 400
    ) if $validation->has_error;
    $expiration = DateTime::Format::Pg->parse_datetime($validation->param('expiration'))
      if $validation->is_valid('expiration');
    my $apikey = $user->api_keys->create({t_expiration => $expiration});
    $self->render(json => {id => $apikey->id, key => $apikey->key, t_expiration => $apikey->t_expiration});
}

=over 4

=item list_api_keys()

List API keys of the current user.

=back

=cut

sub list_api_keys ($self) {
    my $user = $self->current_user;
    my @keys = map {
        {
            key => $_->key,
            t_expiration => $_->t_expiration,
            t_created => $_->t_created,
            t_updated => $_->t_updated,
        }
    } $user->api_keys->all;
    $self->render(json => \@keys);
}

1;
