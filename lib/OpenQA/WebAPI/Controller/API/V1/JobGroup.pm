# Copyright 2016-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::JobGroup;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema::Result::JobGroups;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::JobGroup

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::JobGroup;

=head1 DESCRIPTION

Implements API methods to access group of jobs.

=head1 METHODS

=cut

# Helper methods

=over 4

=item is_parent()

Reports true if the job group given to the method is a parent group.

=back

=cut

sub is_parent {
    my ($self) = @_;
    return $self->req->url->path =~ qr/.*\/parent_groups/;
}

=over 4

=item resultset()

Returns results for a set of groups.

=back

=cut

sub resultset {
    my ($self) = @_;
    return $self->schema->resultset($self->is_parent ? 'JobGroupParents' : 'JobGroups');
}

=over 4

=item find_group()

Returns information from a job group given its ID.

=back

=cut

sub find_group {
    my ($self) = @_;

    my $group_id = $self->param('group_id');
    if (!defined $group_id) {
        $self->render(json => {error => 'No group ID specified'}, status => 400);
        return;
    }

    my $group = $self->resultset->find($group_id);
    if (!$group) {
        $self->render(json => {error => "Job group $group_id does not exist"}, status => 404);
        return;
    }

    return $group;
}

=over 4

=item load_properties()

Returns the specified parameter which match job group columns as a hash. The has is used to
create or update a job group via DBIx.

=back

=cut

sub load_properties {
    my ($self) = @_;

    if (my $cached_properties = $self->{cached_properties}) {
        return $cached_properties;
    }

    my %properties;
    for my $param ($self->resultset->result_source->columns) {
        my $value = $self->validation->param($param);
        next unless defined $value;
        if ($param eq 'parent_id') {
            $properties{$param} = ($value eq 'none') ? undef : $value;
        }
        elsif ($param eq 'size_limit_gb') {
            $properties{$param} = ($value eq '') ? undef : $value;
        }
        else {
            $properties{$param} = $value;
        }
    }

    return $self->{cached_properties} = \%properties;
}

# Actual API entry points

=over 4

=item list()

Shows a list jobs belonging to a job group given its ID, or a list of all jobs.
For each job in the list, all relevant information - with the exception of
timestamps - is also returned as a list of indexed lists.

=back

=cut

sub list {
    my ($self) = @_;

    my $groups;
    my $group_id = $self->param('group_id');
    if ($group_id) {
        $groups = $self->resultset->search({id => $group_id});
        return $self->render(json => {error => "Group $group_id does not exist"}, status => 404) unless $groups->count;
    }
    else {
        $groups = $self->resultset;
    }

    my @results;
    while (my $group = $groups->next) {
        my %data;
        for my $column_name ($group->result_source->columns) {
            # don't return time stamps - it wouldn't be wrong, but it would make writing tests more complex
            next if $column_name =~ qr/^t_.*/;
            $data{$column_name} = $group->$column_name;
        }
        push(@results, \%data);
    }
    $self->render(json => \@results);
}

=over 4

=item check_top_level_group()

Check existing job group on top level to prevent create/update duplicate.

=back

=cut

sub check_top_level_group {
    my ($self, $group_id) = @_;

    return 0 if $self->is_parent;
    my $properties = $self->load_properties;
    my $conditions = {name => $properties->{name}, parent_id => undef};
    $conditions->{id} = {'!=', $group_id} if $group_id;
    return $self->resultset->search($conditions);
}

sub _validate_common_properties {
    my ($self) = @_;
    my $validation = $self->validation;
    $validation->optional('parent_id')->like(qr/^(none|[0-9]+)\z/);
    $validation->optional('size_limit_gb')->like(qr/^(|[0-9]+)\z/);
    $validation->optional('build_version_sort')->in(0, 1);
    $validation->optional('keep_logs_in_days')->num(0);
    $validation->optional('keep_important_logs_in_days')->num(0);
    $validation->optional('keep_results_in_days')->num(0);
    $validation->optional('keep_important_results_in_days')->num(0);
    $validation->optional('default_priority')->num(0);
    $validation->optional('carry_over_bugrefs')->num(0, 1);
    $validation->optional('description');
}

=over 4

=item create()

Creates a new job group given a name. Prevents the creation of job groups with the same name.

=over 8

=item name

The name of the group to be created.

=back

Returns a 400 code on error or a 500 code if the group already exists.

=back

=cut

sub create {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->required('name')->like(qr/^(?!\s*$).+/);
    $validation->optional('default_keep_logs_in_days')->num(0);
    $validation->optional('default_keep_important_logs_in_days')->num(0);
    $validation->optional('default_keep_results_in_days')->num(0);
    $validation->optional('default_keep_important_results_in_days')->num(0);
    $self->_validate_common_properties;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $check = $self->check_top_level_group;
    if ($check != 0) {
        return $self->render(
            json => {error => 'Unable to create group with existing name ' . $validation->param('name')},
            status => 500
        );
    }

    my $properties = $self->load_properties;

    my $id;
    eval { $id = $self->resultset->create($properties)->id };
    if ($@) {
        return $self->render(json => {error => $@}, status => 400);
    }

    $self->emit_event(openqa_jobgroup_create => {id => $id});
    $self->render(json => {id => $id});
}

=over 4

=item update()

Updates the properties of a job group.

=back

=cut

sub update {
    my ($self) = @_;

    my $group = $self->find_group;
    return unless $group;

    my $validation = $self->validation;
    # Don't check group name if sorting group by dragging
    $validation->required('name')->like(qr/^(?!\s*$).+/) unless $validation->optional('drag')->num(1)->is_valid;
    $validation->optional('sort_order')->num(0);
    $self->_validate_common_properties;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $check = $self->check_top_level_group($group->id);
    if ($check != 0) {
        return $self->render(
            json => {error => 'Unable to update group due to not allow duplicated job group on top level'},
            status => 500
        );
    }

    my $properties = $self->load_properties;
    my $id;
    eval { $id = $group->update($properties)->id };
    if ($@) {
        return $self->render(json => {error => $@}, status => 400);
    }

    $self->emit_event(openqa_jobgroup_update => {id => $id});
    $self->render(json => {id => $id});
}

=over 4

=item list_jobs()

List jobs belonging to a job group.

=back

=cut

sub list_jobs {
    my ($self) = @_;

    my $group = $self->find_group;
    return unless $group;

    my @jobs;
    if ($self->param('expired')) {
        @jobs = @{$group->find_jobs_with_expired_results};
    }
    else {
        @jobs = $group->jobs;
    }
    return $self->render(json => {ids => [sort map { $_->id } @jobs]});
}

=over 4

=item delete()

Deletes a job group. Verifies that it is not empty before attempting to remove.

=back

=cut

sub delete {
    my ($self) = @_;

    my $group = $self->find_group();
    return unless $group;

    if ($group->can('jobs') && scalar($group->jobs) != 0) {
        return $self->render(json => {error => 'Job group ' . $group->id . ' is not empty'}, status => 400);
    }

    my $res = $group->delete;
    return $self->render(
        json => {error => 'Specified job group ' . $group->id . ' exist but can not be deleted, though'})
      unless $res;
    my $event_data = {id => $res->id};
    $self->emit_event(openqa_jobgroup_delete => $event_data);
    $self->render(json => $event_data);
}

1;
