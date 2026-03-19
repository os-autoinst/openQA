# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Schema;
use OpenQA::WebSockets::Model::Status;

sub register ($self, $app, $conf = undef) {
    $app->helper(log_name => sub ($c) { 'websockets' });

    $app->helper(schema => sub ($c) { OpenQA::Schema->singleton });
    $app->helper(status => sub ($c) { OpenQA::WebSockets::Model::Status->singleton });
}

1;
