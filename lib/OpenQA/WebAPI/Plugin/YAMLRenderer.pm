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

use YAML::XS;
use Try::Tiny;

sub register {
    my ($self, $app) = @_;

    # register YAML output type
    $app->types->type(yaml => 'text/yaml;charset=UTF-8');
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
            my $validator = JSON::Validator->new;
            my $schema;
            my @errors;

            try {
                die "No valid schema specified\n" unless ($schema_filename // '') =~ /^[^.\/]+\.yaml$/;
                # Note: Using the schema filename; slurp'ed text isn't detected as YAML
                my $schema_abspath = $self->app->home->child('public', 'schema', $schema_filename)->to_string;

                if ($validate_schema) {
                    # Validate the schema: catches errors in type names and definitions
                    $validator = $validator->load_and_validate_schema($schema_abspath);
                    $schema    = $validator->schema;
                }
                else {
                    $schema = $validator->schema($schema_abspath);
                }
            }
            catch {
                # The first line of the backtrace gives us the error message we want
                push @errors, (split /\n/, $_)[0];
            };
            if ($schema) {
                # Note: Don't pass $schema here, that won't work
                push @errors, $validator->validate($yaml);
            }
            return \@errors;
        });
}

1;
