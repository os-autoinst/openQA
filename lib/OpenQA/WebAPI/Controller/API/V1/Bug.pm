# Copyright (C) 2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Controller::API::V1::Bug;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
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
Additionally "delta" can be set to a timespan, 3600 seconds by default.

The optional parameter "created_since" limits the results to bugs reported in the given timespan.

Note: Only one of "refreshable" and "created_since" can be used at the same time.

=back

=cut

sub list {
    my ($self) = @_;

    my $schema = $self->schema;
    my $bugs;
    if ($self->param('refreshable')) {
        my $delta = $self->param('delta') || 3600;
        $bugs = $schema->resultset("Bugs")->search(
            {
                -or => {
                    refreshed => 0,
                    t_updated => {'<=' => time2str('%Y-%m-%d %H:%M:%S', time - $delta, 'UTC')}
                },
                existing => 1
            });
    }
    elsif (my $delta = $self->param('created_since')) {
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

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

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

    my $schema = $self->schema;
    my $bug    = $schema->resultset("Bugs")->find({bugid => $self->param('bugid')});

    if ($bug) {
        $self->render(json => {error => 1});
        return;
    }

    $bug = $schema->resultset("Bugs")->create({bugid => $self->param('bugid'), %{$self->get_bug_values}});
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

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

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

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

    $self->emit_event('openqa_bug_delete', {id => $bug->id, bugid => $bug->bugid});
    $bug->delete;
    $self->render(json => {result => 1});
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

    return {
        title      => $self->param('title'),
        priority   => $self->param('priority'),
        assigned   => $self->param('assigned') ? 1 : 0,
        assignee   => $self->param('assignee'),
        open       => $self->param('open') ? 1 : 0,
        status     => $self->param('status'),
        resolution => $self->param('resolution'),
        existing   => $self->param('existing') ? 1 : 0,
        t_updated  => time2str('%Y-%m-%d %H:%M:%S', time, 'UTC'),
        refreshed  => 1
    };
}

1;
