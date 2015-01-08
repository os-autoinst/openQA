# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Plugin::REST;

use strict;
use warnings;

use base 'Mojolicious::Plugin';

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
        }
    );

    # special anchor tag for post links
    $app->helper(
        link_post => sub {
            my $self = shift;
            $self->action_link('post', @_);
        }
    );

    # special anchor tag for delete links
    $app->helper(
        link_delete => sub {
            my $self = shift;
            $self->action_link('delete', @_);
        }
    );

    # Allow "_method" query parameter to override request method
    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            return unless my $method = $c->req->param('_method');
            $c->req->method($method);
        }
    );
}

1;
# vim: set sw=4 et:
