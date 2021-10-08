# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Table;
use Mojo::Base 'Mojolicious::Controller';

sub admintable {
    my ($self, $template) = @_;
    $self->render("admin/$template/index");
}

1;
