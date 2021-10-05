# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::TestSuite;
use Mojo::Base 'OpenQA::WebAPI::Controller::Admin::Table';

sub index {
    shift->SUPER::admintable('test_suite');
}

1;
