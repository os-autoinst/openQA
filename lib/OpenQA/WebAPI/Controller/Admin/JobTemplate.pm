# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::JobTemplate;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($self) {
    my $schema = $self->schema;
    my $group = $schema->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    $self->stash(
        group => $group,
        yaml_template => $group->template,
    );

    $self->render('admin/job_template/index');
}

1;
