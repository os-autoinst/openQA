# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Machine;
use Mojo::Base 'OpenQA::WebAPI::Controller::Admin::Table';

sub index {
    shift->SUPER::admintable('machine');
}

1;
