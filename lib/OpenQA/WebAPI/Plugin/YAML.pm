# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::YAML;
use Mojo::Base 'Mojolicious::Plugin';
use OpenQA::YAML 'validate_data';

use Try::Tiny;

sub register {
    my ($self, $app) = @_;

    $app->renderer->add_handler(
        yaml => sub {
            my ($renderer, $c, $output, $options) = @_;
            delete $options->{encoding};
            $$output = $c->stash->{yaml};
        });
    $app->hook(
        before_render => sub {
            my ($c, $args) = @_;
            if (exists $args->{yaml} || exists $c->stash->{yaml}) {
                $args->{format} = 'yaml';
                $args->{handler} = 'yaml';
            }
        });

    $app->helper(
        # Validates the given YAML job group template using JSON schema. The parameter validate_schema enables
        # validation of the schema itself which can be useful for development and testing.
        # Returns an array of errors found during validation or otherwise an empty array.
        validate_yaml => sub {
            my ($self, $yaml, $schema_filename, $validate_schema) = @_;

            my @errors;

            try {
                my $schema_abspath = $self->app->home->child('public', 'schema', $schema_filename)->to_string;
                my $errors = validate_data(
                    data => $yaml,
                    schema_file => $schema_abspath,
                    validate_schema => $validate_schema,
                );
                push @errors, @$errors;

            }
            catch {
                # The first line of the backtrace gives us the error message we want
                push @errors, (split /\n/, $_)[0];
            };
            return \@errors;
        });
}

1;
