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
    $self->stash(
        group => $group,
        yaml_template => $yaml,
    );

    my @machines = $schema->resultset('Machines')->search(undef, {order_by => 'name'});
    $self->stash(machines => \@machines);
    my @tests = $schema->resultset('TestSuites')->search(undef, {order_by => 'name'});
    $self->stash(tests => \@tests);

    $self->render('admin/job_template/index');
}

1;
