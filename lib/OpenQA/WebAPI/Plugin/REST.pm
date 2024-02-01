# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::REST;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Scalar::Util 'blessed';
use Carp 'croak';

sub register ($self, $app, $config) {
    # special anchor tag with data-method
    $app->helper(
        action_link => sub ($c, $method, $content, @args) {
            my $url = $content;
            return '' unless $c->is_operator;
            croak 'url is not a url' unless blessed $url && $url->isa('Mojo::URL');
            return $c->tag('a', href => $url, 'data-method' => $method, @args);
        });

    # special anchor tag for post links
    $app->helper(link_post => sub ($c, @args) { $c->action_link('post', @args) });

    # Allow "_method" query parameter to override request method
    $app->hook(
        before_dispatch => sub ($c) {
            return unless my $method = $c->req->param('_method');
            $c->req->method($method);
        });
}

1;
