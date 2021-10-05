# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Plugin::CSRF;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app, $config) = @_;

    # replace form_for with our own that puts the csrf token in there
    die "failed to find form_for" unless my $form_for = delete $app->renderer->helpers->{form_for};
    $app->helper(
        form_for => sub {
            my $self = shift;
            my $code = $_[-1];
            if (defined $code && ref $code eq 'CODE') {
                $_[-1] = sub {
                    $self->csrf_field . $code->();
                };
            }
            return $self->$form_for(@_);
        });

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
        });
}

1;
