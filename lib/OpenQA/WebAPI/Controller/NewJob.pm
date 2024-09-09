# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::NewJob;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub create ($self) {
    warn "route called";
    $self->render(template => "NewJob/create");
}


1;
