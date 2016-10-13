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

sub list {
    my ($self) = @_;

    my $group_id = $self->param('group_id');
    my $job_groups;
    if ($group_id) {
        $job_groups = $self->db->resultset('JobGroups')->search({id => $group_id});
        return $self->render(json => {error => "Job group $group_id does not exist"}, status => 400) unless $job_groups->count;
    }
    else {
        $job_groups = $self->db->resultset('JobGroups');
    }

    my @results;
    while (my $group = $job_groups->next) {
        push(
            @results,
            {
                id                             => $group->id,
                name                           => $group->name,
                parent_id                      => $group->parent_id,
                size_limit_gb                  => $group->size_limit_gb,
                keep_logs_in_days              => $group->keep_logs_in_days,
                keep_important_logs_in_days    => $group->keep_important_logs_in_days,
                keep_results_in_days           => $group->keep_results_in_days,
                keep_important_results_in_days => $group->keep_important_results_in_days,
                default_priority               => $group->default_priority,
                sort_order                     => $group->sort_order,
                description                    => $group->description
            });
    }
    $self->render(json => \@results);
}

sub load_properties {
    my ($self) = @_;

    my %properties;
    for my $param (qw(name parent_id size_limit_gb keep_logs_in_days keep_important_logs_in_days keep_results_in_days keep_important_results_in_days default_priority sort_order description)) {
        my $value = $self->param($param);
        $properties{$param} = $value if defined($value);
    }
    return \%properties;
}

sub create {
    my ($self) = @_;

    my $group_name = $self->param('name');
    return $self->render(json => {error => 'No group name specified'}, status => 400) unless $group_name;

    my $group = $self->db->resultset('JobGroups')->create($self->load_properties);
    return $self->render(json => {error => 'Unable to create job group with specified properties'}, status => 400) unless $group;

    $self->render(json => {id => $group->id});
}

sub update {
    my ($self) = @_;

    my $group_id = $self->param('group_id');
    my $group    = $self->db->resultset('JobGroups')->find($group_id);
    return $self->render(json => {error => "Job group $group_id does not exist"}, status => 400) unless $group;

    my $res = $group->update($self->load_properties);
    return $self->render(json => {error => "Specified job group $group_id exist but unable to update, though"}) unless $res;
    $self->render(json => {id => $res->id});
}

sub delete {
    my ($self) = @_;

    my $group_id = $self->param('group_id');
    my $group    = $self->db->resultset('JobGroups')->find($group_id);
    if (!$group) {
        return $self->render(json => {error => "Job group $group_id does not exist"}, status => 400);
    }
    if (scalar($group->jobs) != 0) {
        return $self->render(json => {error => "Job group $group_id is not empty"}, status => 400);
    }

    my $res = $group->delete;
    return $self->render(json => {error => "Specified job group $group_id exist but can not be deleted, though"}) unless $res;
    $self->render(json => {id => $res->id});
}

1;
