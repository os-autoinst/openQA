# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Schema;
use OpenQA::WebSockets::Model::Status;

sub register {
    my ($self, $app) = @_;

    $app->helper(log_name => sub { 'websockets' });

    $app->helper(schema => sub { OpenQA::Schema->singleton });
    $app->helper(status => sub { OpenQA::WebSockets::Model::Status->singleton });
}

1;
