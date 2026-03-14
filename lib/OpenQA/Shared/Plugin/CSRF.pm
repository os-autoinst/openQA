# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Plugin::CSRF;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $conf = undef) {
    # replace form_for with our own that puts the csrf token in there
    die 'failed to find form_for' unless my $form_for = delete $app->renderer->helpers->{form_for};
    $app->helper(
        form_for => sub ($c, @args) {
            my $code = $args[-1];
            if (defined $code && ref $code eq 'CODE') {
                $args[-1] = sub {
                    $c->csrf_field . $code->();
                };
            }
            return $c->$form_for(@args);
        });

    # require CSRF token for all requests that are not GET or HEAD
    $app->helper(
        valid_csrf => sub ($c) {
            my $validation = $c->validation;
            if ($validation->csrf_protect->has_error('csrf_token')) {
                $c->app->log->debug('Bad CSRF token');
                return 0;
            }
            return 1;
        });
}

1;
