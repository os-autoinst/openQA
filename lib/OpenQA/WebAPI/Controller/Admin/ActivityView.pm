# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::ActivityView;
use Mojo::Base 'Mojolicious::Controller';

sub user {
    my ($self) = @_;

    $self->render('admin/activity_view/user');
}

1;
