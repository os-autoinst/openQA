# Copyright SUSE LLC
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

    # Map deprecated "format" parameter to "_format" for content negotiation
    # and allow "_method" parameter to override request method
    $app->hook(
        before_dispatch => sub ($c) {
            my $req = $c->req;
            for my $params ($req->query_params, $req->body_params) {
                my $formats = $params->every_param('format');
                next unless @$formats;
                $params->remove('format');
                unless (@{$params->every_param('_format')}) {
                    $params->append(_format => $_) for @$formats;
                }
            }
            # Clear cached merged params in Mojo::Message::Request so param() re-reads updated sources
            delete $req->{params};
            return unless my $method = $req->param('_method');
            $req->method($method);
        });
}

1;
