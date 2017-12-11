# Copyright (C) 2016 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::JobGroup;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Schema::Result::JobGroups;

# Helper methods

sub is_parent {
    my ($self) = @_;
    return $self->req->url->path =~ qr/.*\/parent_groups/;
}

sub resultset {
    my ($self) = @_;
    return $self->db->resultset($self->is_parent ? 'JobGroupParents' : 'JobGroups');
}

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

sub load_properties {
    my ($self) = @_;

    my %properties;
    for my $param ($self->resultset->result_source->columns) {
        my $value = $self->param($param);
        if (defined($value)) {
            if ($param eq 'parent_id') {
                $properties{$param} = ($value eq 'none') ? undef : $value;
            }
            else {
                $properties{$param} = $value;
            }
        }
    }
    return \%properties;
}

# Actual API entry points

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

# check existing job group on top level to prevent create/update duplicate
sub check_top_level_group {
    my ($self, $group_id) = @_;

    return 0 if $self->is_parent;
    my $properties = $self->load_properties;
    my $conditions = {name => $properties->{name}, parent_id => undef};
    $conditions->{id} = {'!=', $group_id} if $group_id;
    return $self->resultset->search($conditions);
}

sub create {
    my ($self) = @_;

    my $group_name = $self->param('name');
    return $self->render(json => {error => 'No group name specified'}, status => 400) unless $group_name;

    my $check = $self->check_top_level_group;
    if ($check != 0) {
        return $self->render(
            json   => {error => 'Unable to create group due to not allow duplicated job group on top level'},
            status => 500
        );
    }

    my $group = $self->resultset->create($self->load_properties);
    return $self->render(json => {error => 'Unable to create group with specified properties'}, status => 400)
      unless $group;

    $self->render(json => {id => $group->id});
}

sub update {
    my ($self) = @_;

    my $group = $self->find_group;
    return unless $group;

    my $check = $self->check_top_level_group($group->id);
    if ($check != 0) {
        return $self->render(
            json   => {error => 'Unable to update group due to not allow duplicated job group on top level'},
            status => 500
        );
    }

    my $res = $group->update($self->load_properties);
    return $self->render(json => {error => 'Specified job group ' . $group->id . ' exist but unable to update, though'})
      unless $res;
    $self->render(json => {id => $res->id});
}

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
    $self->render(json => {id => $res->id});
}

1;
