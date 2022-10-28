# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::Controller::API;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Scheduler;

sub wakeup ($self) {
    OpenQA::Scheduler::wakeup();
    $self->render(text => 'ok');
}

1;
