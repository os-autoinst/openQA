# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Scheduler;

sub wakeup {
    my $self = shift;
    OpenQA::Scheduler::wakeup();
    $self->render(text => 'ok');
}

1;
