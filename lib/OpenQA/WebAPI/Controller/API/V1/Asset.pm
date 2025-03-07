# Copyright 2015-2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Asset;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use DBIx::Class::ResultClass::HashRefInflator;
use OpenQA::App;
use OpenQA::Utils;
use List::Util qw(min);
use Feature::Compat::Try;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Asset

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Asset;

=head1 DESCRIPTION

OpenQA API implementation for assets handling methods.

=head1 METHODS

=over 4

=item register()

Register an asset given its name and type. Returns a code of 200 on success and of 400 on error.

=back

=cut

sub register {
    my ($self) = @_;

    my $type = $self->param('type');
    my $name = $self->param('name');

    my $asset = $self->schema->resultset('Assets')->register($type, $name);
    return $self->render(json => {error => 'registering asset failed'}, status => 400) unless $asset;

    $self->emit_event('openqa_asset_register', {id => $asset->id, type => $type, name => $name});
    $self->render(json => {id => $asset->id}, status => 200);
}

=over 4

=item list()

Returns a list of all assets present in the system. For each asset relevant information such
as its id, name, timestamp of creation and type is included.

=back

=cut

sub list ($self) {
    my $schema = $self->schema;
    my $limits = OpenQA::App->singleton->config->{misc_limits};

    my $validation = $self->validation;
    $validation->optional('limit')->num;
    $validation->optional('offset')->num;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $limit = min($limits->{assets_max_limit}, $validation->param('limit') // $limits->{assets_default_limit});
    my $offset = $validation->param('offset') // 0;

    # We request one more than the limit to check if there are more results for pagination
    my $rs = $schema->resultset('Assets')->search({}, {rows => $limit + 1, offset => $offset});
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my @all = $rs->all;

    # Pagination
    pop @all if my $has_more = @all > $limit;
    $self->pagination_links_header($limit, $offset, $has_more);

    $self->render(json => {assets => \@all});
}

sub trigger_cleanup {
    my ($self) = @_;

    my $res = $self->gru->enqueue_limit_assets();
    $self->render(json => {status => 'ok', gru_id => $res->{gru_id}});
}

=over 4

=item get()

Returns information for a specific asset given its id or its type and name. Information
returned the asset id, name, timestamp of creation and type. Returns a code of 200
on success and of 404 on error.

=back

=cut

sub get {
    my $self = shift;
    my $schema = $self->schema;

    my %args;
    for my $arg (qw(id type name)) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    my $rs = $schema->resultset('Assets')->search(\%args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    if ($rs && $rs->single) {
        $self->render(json => $rs->single, status => 200);
    }
    else {
        $self->render(json => {}, status => 404);
    }
}

=over 4

=item delete()

Removes an asset from the system given its id or its type and name. Returns the
number of assets removed.

=back

=cut

sub delete {
    my ($self) = @_;

    my %args;
    for my $arg (qw(id type name)) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    my $asset = $self->schema->resultset('Assets')->search(\%args);
    return $self->render(
        json =>
          {error => 'The asset might have already been removed and only the cached view has not been updated yet.'},
        status => 404
    ) if $asset->count == 0;
    my $rs;
    try { $rs = $asset->delete_all }
    catch ($e) { return $self->render(json => {error => $e}, status => 409) }
    $self->emit_event('openqa_asset_delete', \%args);
    $self->render(json => {count => $rs}, status => 200);
}

1;
