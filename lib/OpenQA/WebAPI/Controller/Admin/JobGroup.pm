# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::JobGroup;
use Mojo::Base 'Mojolicious::Controller';
use Feature::Compat::Try;

sub index {
    my ($self) = @_;

    my $schema = $self->schema;
    my $parent_groups
      = $schema->resultset('JobGroupParents')->search(undef, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]});
    my $groups
      = $schema->resultset('JobGroups')->search(undef, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]});
    my $for_editor = $schema->resultset('JobGroupParents')->job_groups_and_parents;

    $self->stash('job_groups_and_parents_for_editor', $for_editor);
    $self->stash('parent_groups', $parent_groups);
    $self->stash('groups', $groups);
    $self->render('admin/group/index');
}

sub group_page {
    my ($self, $resultset, $template) = @_;

    my $group_id = $self->param('groupid');
    return $self->reply->not_found unless $group_id;

    my $group = $self->schema->resultset($resultset)->find($group_id);
    return $self->reply->not_found unless $group;

    $self->stash('group', $group);
    $self->stash('index', $group->sort_order);
    $self->stash('parent_id', $group->can('parent_id') && $group->parent_id // 'none');
    $self->render($template);
}

sub parent_group_row {
    my ($self) = @_;
    $self->group_page('JobGroupParents', 'admin/group/parent_group_row');
}

sub job_group_row {
    my ($self) = @_;
    $self->group_page('JobGroups', 'admin/group/job_group_row');
}

sub edit_parent_group {
    my ($self) = @_;
    $self->group_page('JobGroupParents', 'admin/group/parent_group_property_editor');
}

1;
