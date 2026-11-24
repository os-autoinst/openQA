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
    # and allow "_method" parameter to override request method. Only the merged
    # parameter view is rewritten, not the request URL: the URL is the basis of
    # the API signature verification (see OpenQA::Shared::Controller::Auth::_key_auth).
    $app->hook(
        before_dispatch => sub ($c) {
            my $req = $c->req;
            # Merge like Mojo::Message::Request::params: body parameters first, query parameters last
            $req->{params} = _with_mapped_format($req->body_params)->append(_with_mapped_format($req->query_params));
            return unless my $method = $req->param('_method');
            $req->method($method);
        });
}

sub _with_mapped_format ($params) {
    my $mapped = $params->clone;
    my $formats = $mapped->every_param('format');
    return $mapped unless @$formats;
    $mapped->remove('format');
    unless (@{$mapped->every_param('_format')}) {
        $mapped->append(_format => $_) for @$formats;
    }
    return $mapped;
}

1;
