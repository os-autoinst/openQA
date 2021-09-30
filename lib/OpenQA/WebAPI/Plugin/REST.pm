# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::REST;
use Mojo::Base 'Mojolicious::Plugin';

use Scalar::Util ();
use Carp ();

sub register {

    my ($self, $app, $config) = @_;

    # special anchor tag with data-method
    $app->helper(
        action_link => sub {
            my ($self, $method, $content) = (shift, shift, shift);
            my $url = $content;

            if ($self->is_operator) {
                # Content
                unless (ref $_[-1] eq 'CODE') {
                    $url = shift;
                    push @_, $content;
                }

                Carp::croak "url is not a url"
                  unless Scalar::Util::blessed $url && $url->isa('Mojo::URL');

                return $self->tag('a', href => $url, 'data-method' => $method, @_);
            }
            else {
                return '';
            }
        });

    # special anchor tag for post links
    $app->helper(
        link_post => sub {
            my $self = shift;
            $self->action_link('post', @_);
        });

    # Allow "_method" query parameter to override request method
    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            return unless my $method = $c->req->param('_method');
            $c->req->method($method);
        });
}

1;
