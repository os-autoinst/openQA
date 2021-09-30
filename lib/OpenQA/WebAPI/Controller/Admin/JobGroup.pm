# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::JobGroup;
use Mojo::Base 'Mojolicious::Controller';

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

sub connect {
    my ($self) = @_;

    my $schema = $self->schema;
    $self->stash('group', $schema->resultset('JobGroups')->find($self->param('groupid')));
    my $products = $schema->resultset('Products')->search(undef, {order_by => 'name'});
    $self->stash('products', $products);
    my $tests = $schema->resultset('TestSuites')->search(undef, {order_by => 'name'});
    $self->stash('tests', $tests);
    my $machines = $schema->resultset('Machines')->search(undef, {order_by => 'name'});
    $self->stash('machines', $machines);

    $self->render('admin/group/connect');
}

sub save_connect {
    my ($self) = @_;

    my $schema = $self->schema;
    my $group = $schema->resultset("JobGroups")->find($self->param('groupid'));
    if (!$group) {
        $self->flash(error => 'Specified group ID ' . $self->param('groupid') . 'doesn\'t exist.');
        return $self->redirect_to('admin_groups');
    }

    my $values = {
        prio => $self->param('prio') // $group->default_priority,
        product_id => $self->param('medium'),
        machine_id => $self->param('machine'),
        group_id => $group->id,
        test_suite_id => $self->param('test')};
    eval { $schema->resultset("JobTemplates")->create($values)->id };
    if ($@) {
        $self->flash(error => $@);
        return $self->redirect_to('job_group_new_media', groupid => $group->id);
    }
    else {
        $self->emit_event('openqa_jobgroup_connect', $values);
        return $self->redirect_to('admin_job_templates', groupid => $group->id);
    }
}

1;
