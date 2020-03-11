# Copyright (C) 2019 SUSE LINUX GmbH, Nuernberg, Germany
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Plugin::YAMLRenderer;
use Mojo::Base 'Mojolicious::Plugin';
use OpenQA::JobTemplates 'validate_data';

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
                $args->{format}  = 'yaml';
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
                my $errors         = validate_data(
                    data            => $yaml,
                    schema_file     => $schema_abspath,
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
