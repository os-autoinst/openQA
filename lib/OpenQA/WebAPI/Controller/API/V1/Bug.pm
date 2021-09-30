# Copyright 2017-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Bug;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
use Time::Seconds;
use Try::Tiny;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Bug

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Bug;

=head1 DESCRIPTION

OpenQA API implementation for bug handling methods.

=head1 METHODS

=over 4

=item list()

Returns a dictionary of bugs reported in the system of the form { id: bug } where the key
is the ID in the database and the value is the external bug, eg. bsc#123 or poo#123.

The optional parameter "refreshable" limits the results to bugs not updated recently.
Bugs that were already checked and don't actually exist in the bugtracker are not returned
as there are no updates on non-existent bugs expected.
Additionally "delta" can be set to a timespan, 1 hour by default.

The optional parameter "created_since" limits the results to bugs reported in the given timespan.

Note: Only one of "refreshable" and "created_since" can be used at the same time.

=back

=cut

sub list {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->optional('refreshable')->num(0, 1);
    $validation->optional('delta')->num(0);
    $validation->optional('created_since')->num(0);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $schema = $self->schema;
    my $bugs;
    if ($validation->param('refreshable')) {
        my $delta = $validation->param('delta') || ONE_HOUR;
        $bugs = $schema->resultset("Bugs")->search(
            {
                -or => {
                    refreshed => 0,
                    t_updated => {'<=' => time2str('%Y-%m-%d %H:%M:%S', time - $delta, 'UTC')}
                },
                existing => 1
            });
    }
    elsif (my $delta = $validation->param('created_since')) {
        $bugs = $schema->resultset("Bugs")->search(
            {
                t_created => {'>=' => time2str('%Y-%m-%d %H:%M:%S', time - $delta, 'UTC')}});
    }
    else {
        $bugs = $schema->resultset("Bugs");
    }

    my %ret = map { $_->id => $_->bugid } $bugs->all;
    $self->render(json => {bugs => \%ret});
}

=over 4

=item show()

Returns information for a bug given its id in the system. Information includes the internal
(openQA-specific) and the external bug id. Also shows the bug's title, priority, whether its
assigned or not and its assignee, whether its open or not, status, resolution, whether its an
existing bug or not, and the date when the bug was last updated in the system.

=back

=cut

sub show {
    my ($self) = @_;

    my $bug = $self->schema->resultset("Bugs")->find($self->param('id'));
    return $self->reply->not_found unless $bug;

    my %json = map { $_ => $bug->get_column($_) }
      qw(assigned assignee bugid existing id open priority refreshed resolution status t_created t_updated title);
    $self->render(json => \%json);
}

=over 4

=item create()

Creates a new bug in the system. This method will check for the existence of a bug with the same
external bug id, in which case the method fails with an error code of 1. Otherwise, the new bug
is created with the bug values passed as arguments.

=back

=cut

sub create {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->required('bugid');
    $self->_validate_bug_values;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $schema = $self->schema;
    my $bugid = $validation->param('bugid');
    my $bug = $schema->resultset("Bugs")->find({bugid => $bugid});
    return $self->render(json => {error => 1}) if $bug;

    $bug = $schema->resultset("Bugs")->create({bugid => $bugid, %{$self->get_bug_values}});
    $self->emit_event('openqa_bug_create', {id => $bug->id, bugid => $bug->bugid, fromapi => 1});
    $self->render(json => {id => $bug->id});
}

=over 4

=item update()

Updates the information of a bug given its id and a set of bug values to update. Returns
the id of the bug, or an error if the bug id is not found in the system.

=back

=cut

sub update {
    my ($self) = @_;

    my $bug = $self->schema->resultset("Bugs")->find($self->param('id'));
    return $self->reply->not_found unless $bug;

    my $validation = $self->validation;
    $self->_validate_bug_values;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    $bug->update($self->get_bug_values);
    $self->emit_event('openqa_bug_update', {id => $bug->id, bugid => $bug->bugid});
    $self->render(json => {id => $bug->id});
}

=over 4

=item destroy()

Removes a bug from the system given its bug id. Return 1 on success or not found on error.

=back

=cut

sub destroy {
    my ($self) = @_;

    my $bug = $self->schema->resultset("Bugs")->find($self->param('id'));
    return $self->reply->not_found unless $bug;

    $self->emit_event('openqa_bug_delete', {id => $bug->id, bugid => $bug->bugid});
    $bug->delete;
    $self->render(json => {result => 1});
}

=over 4

=item _validate_bug_values()

Internal method to validate the values expected by B<create()> and B<update()>.

=back

=cut

sub _validate_bug_values {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->optional('title');
    $validation->optional('priority');
    $validation->optional('assigned')->num(0, 1);
    $validation->optional('assignee');
    $validation->optional('open')->num(0, 1);
    $validation->optional('status');
    $validation->optional('resolution');
    $validation->optional('existing')->num(0, 1);
    $validation->optional('refreshed')->num(0, 1);
}

=over 4

=item get_bug_values()

Internal method to extract from the query string the named arguments for values that can be
set for a bug: title, priority, whether its assigned or not (assigned), assignee, whether its
an open bug or not (open), status, resolution, whether its an existing bug or not (existing),
and the timestamp of the update operation (t_updated). This method is used by B<create()> and
B<update()>.

=back

=cut

sub get_bug_values {
    my ($self) = @_;

    my $validation = $self->validation;
    return {
        title => $validation->param('title'),
        priority => $validation->param('priority'),
        assigned => $validation->param('assigned') ? 1 : 0,
        assignee => $validation->param('assignee'),
        open => $validation->param('open') ? 1 : 0,
        status => $validation->param('status'),
        resolution => $validation->param('resolution'),
        existing => $validation->param('existing') ? 1 : 0,
        t_updated => time2str('%Y-%m-%d %H:%M:%S', time, 'UTC'),
        refreshed => 1
    };
}

1;
