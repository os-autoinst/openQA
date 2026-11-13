# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime::Format::Pg;
use Feature::Compat::Try;
use List::Util qw(min);
use OpenQA::App;
use OpenQA::Constants 'API_KEY_COMMENT_MAX_LENGTH';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::User

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::User;

=head1 DESCRIPTION

Implements User API.

=head1 METHODS

=over 4

=item list()

List users. Accepts optional pagination parameters C<limit> and C<offset>,
and optional C<deleted> query parameter to filter by active or deleted users.

=back

=cut

sub list ($self) {
    my $validation = $self->validation;
    $validation->optional('limit')->num;
    $validation->optional('offset')->num;
    $validation->optional('deleted')->num(0, 1);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $limits = OpenQA::App->singleton->config->{misc_limits};
    my $limit
      = min($limits->{admin_table_max_limit}, $validation->param('limit') // $limits->{admin_table_default_limit});
    my $offset = $validation->param('offset') // 0;

    my $deleted = $validation->param('deleted');
    my $condition
      = !defined $deleted ? {}
      : $deleted == 1 ? {deleted_at => {'!=' => undef}}
      : {deleted_at => undef};

    my $users = $self->schema->resultset('Users');
    my @paged = $users->search($condition, {rows => $limit + 1, offset => $offset, order_by => 'id'})->all;
    pop @paged if my $has_more = @paged > $limit;
    $self->pagination_links_header($limit, $offset, $has_more);

    my @users_data = map {
        {
            id => $_->id,
            username => $_->username,
            nickname => $_->nickname,
            fullname => $_->fullname,
            email => $_->email,
            is_operator => $_->is_operator ? 1 : 0,
            is_admin => $_->is_admin ? 1 : 0,
            deleted_at => _format_datetime($_->deleted_at),
            t_created => _format_datetime($_->t_created),
            t_updated => _format_datetime($_->t_updated),
        }
    } @paged;

    $self->render(json => {users => \@users_data});
}

sub _format_datetime ($dt) {
    return undef unless defined $dt;
    return DateTime::Format::Pg->format_datetime($dt);
}

=over 4

=item delete()

Deletes an existing user.

=back

=cut

sub delete ($self) {
    my $user = $self->schema->resultset('Users')->find($self->param('id'));
    return $self->render(json => {error => 'Not found'}, status => 404) unless $user;
    my $username = $user->username;
    $user->anonymize;
    $self->emit_event('openqa_user_deleted', {username => $username});
    $self->render(json => {result => 1});
}

=over 4

=item delete_self()

Delete the current user's own account (anonymize all data).

=back

=cut

sub delete_self ($self) {
    my $user = $self->current_user;
    return $self->render(json => {error => 'Not found'}, status => 404) unless $user;
    return $self->render(json => {error => 'User already deleted'}, status => 400) if $user->is_deleted;
    my $username = $user->username;
    $user->anonymize;
    $self->emit_event('openqa_user_deleted', {username => $username});
    $self->render(json => {result => 1});
}

=over 4

=item create_api_key()

Create a new API key. Accepts optional C<expiration> datetime, optional
C<comment>, C<is_operator>, C<is_admin>, and C<role> (C<admin>|C<operator>|C<user>)
as form params. Returns the key, secret, comment, is_operator, is_admin, and
expiration.

=back

=cut

sub create_api_key ($self) {
    my $user = $self->current_user;
    my $expiration;
    my $validation = $self->validation;
    $validation->optional('expiration', 'seconds_optional')->datetime;
    $validation->optional('comment')->size(0, API_KEY_COMMENT_MAX_LENGTH);
    $validation->optional('is_operator')->in('0', '1');
    $validation->optional('is_admin')->in('0', '1');
    $validation->optional('role')->in('admin', 'operator', 'user');
    return $self->render(
        json => {error => 'Date must be in format ' . DateTime::Format::Pg->format_datetime(DateTime->now())},
        status => 400
    ) if $validation->has_error;

    my $role = $validation->is_valid('role') ? $validation->param('role') : undef;
    my ($is_operator, $is_admin, $role_error) = $self->parse_api_key_roles($role, $validation, $user);
    if ($role_error) {
        return $self->render(
            json => {error => $role_error},
            status => 400
        );
    }

    if (my $perm_error = $self->validate_api_key_role_grant($is_admin, $is_operator, $user)) {
        return $self->render(
            json => {error => $perm_error},
            status => 400
        );
    }

    $expiration
      = $validation->is_valid('expiration')
      ? DateTime::Format::Pg->parse_datetime($validation->param('expiration'))
      : DateTime->now->add(years => 1);
    my $apikey = $user->api_keys->create(
        {
            t_expiration => $expiration,
            comment => $validation->param('comment'),
            is_operator => $is_operator,
            is_admin => $is_admin,
        });
    $self->render(
        json => {
            id => $apikey->id,
            key => $apikey->key,
            secret => $apikey->secret,
            comment => $apikey->comment,
            is_operator => $apikey->is_operator,
            is_admin => $apikey->is_admin,
            t_expiration => $apikey->t_expiration
        });
}

=over 4

=item list_api_keys()

List API keys of the current user. Includes C<comment>, C<is_operator>, and C<is_admin> for each key; the secret is omitted.

=back

=cut

sub list_api_keys ($self) {
    my $user = $self->current_user;
    my @keys = map {
        {
            key => $_->key,
            comment => $_->comment,
            is_operator => $_->is_operator,
            is_admin => $_->is_admin,
            t_expiration => $_->t_expiration,
            t_created => $_->t_created,
            t_updated => $_->t_updated,
        }
    } $user->api_keys->all;
    $self->render(json => {keys => \@keys});
}

=over 4

=item delete_api_key()

Delete a specific API key of the current user.

=back

=cut

sub delete_api_key ($self) {
    my $user = $self->current_user;
    my $key = $user->api_keys->find({key => $self->param('key')});
    return $self->render(json => {error => 'Not found'}, status => 404) unless $key;
    $key->delete;
    $self->render(json => {result => 1});
}

1;
