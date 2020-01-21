# Copyright (C) 2020 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::JobTemplates;

use strict;
use warnings;

use Exporter 'import';
use Carp;
use Try::Tiny;
use JSON::Validator;

our $VERSION   = '0.0.1';
our @EXPORT_OK = qw(
  &validate_data
);

sub validate_data {
    my %args            = @_;
    my $schema_file     = $args{schema_file};
    my $data            = $args{data};
    my $validate_schema = $args{validate_schema};
    my $validator       = JSON::Validator->new;
    my $schema;
    my @errors;

    try {
        # Note: Using the schema filename; slurp'ed text isn't detected as YAML

        if ($validate_schema) {
            # Validate the schema: catches errors in type names and definitions
            $validator = $validator->load_and_validate_schema($schema_file);
            $schema    = $validator->schema;
        }
        else {
            $schema = $validator->schema($schema_file);
        }
    }
    catch {
        # The first line of the backtrace gives us the error message we want
        push @errors, (split /\n/, $_)[0];
    };
    if ($schema) {
        # Note: Don't pass $schema here, that won't work
        push @errors, $validator->validate($data);
    }
    return \@errors;
}

1;
