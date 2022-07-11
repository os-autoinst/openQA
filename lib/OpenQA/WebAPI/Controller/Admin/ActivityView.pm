# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::ActivityView;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub user ($self) { $self->render('admin/activity_view/user') }

1;
