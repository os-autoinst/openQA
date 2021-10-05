# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Product;
use Mojo::Base 'OpenQA::WebAPI::Controller::Admin::Table';

sub index {
    shift->SUPER::admintable('product');
}

1;
