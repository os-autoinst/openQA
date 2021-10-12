# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my ($self) = @_;

    my $schema = $self->schema;
    my $group = $schema->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $yaml = $group->template;
    my $force_yaml_editor
      = defined $yaml || $schema->resultset('JobTemplates')->search({group_id => $group->id}, {rows => 1})->count == 0;
    $self->stash(
        group => $group,
        yaml_template => $yaml,
        force_yaml_editor => $force_yaml_editor,
    );

    my @machines = $schema->resultset("Machines")->search(undef, {order_by => 'name'});
    $self->stash(machines => \@machines);
    my @tests = $schema->resultset("TestSuites")->search(undef, {order_by => 'name'});
    $self->stash(tests => \@tests);

    $self->render('admin/job_template/index');
}

1;
