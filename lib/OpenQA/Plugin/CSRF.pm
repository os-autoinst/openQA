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

package OpenQA::Plugin::CSRF;

use strict;
use warnings;

use base 'Mojolicious::Plugin';

use Scalar::Util ();
use Carp ();

sub register {

    my ($self, $app, $config) = @_;

    # replace form_for with our own that puts the csrf token in
    # there
    my $form_for = delete $app->renderer->helpers->{form_for} or die "failed to find form_for";
    $app->helper(
        form_for => sub {
            my $self = shift;
            my $code = $_[-1];
            if ( defined $code && ref $code eq 'CODE' ) {
                $_[-1] = sub {
                    $self->csrf_field . $code->();
                };
            }
            return $self->$form_for(@_);
        }
    );

    # require CSRF token for all requests that are not GET or HEAD
    $app->helper(
        valid_csrf => sub {
            my $c = shift;

            my $validation = $c->validation;
            if ($validation->csrf_protect->has_error('csrf_token')) {
                $c->app->log->debug("Bad CSRF token");
                return 0;
            }
            return 1;
        }
    );
}

1;
# vim: set sw=4 et:
