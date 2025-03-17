# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::YAML;

use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Carp;
use Feature::Compat::Try;
use JSON::Validator;
use YAML::XS;    # Required by JSON::Validator as a runtime dependency
use YAML::PP 0.027;

our $VERSION = '0.0.1';
our @EXPORT_OK = qw(
  &validate_data &load_yaml &dump_yaml
);

my $YP = _init_yaml_processor();

sub _init_yaml_processor () {
    return YAML::PP->new(
        # '+ Merge' is mnemonic for "Use the default schema PLUS the Merge schema"
        # + stands for the default schema (YAML 1.2 Core)
        # https://metacpan.org/pod/YAML::PP::Schema::Core
        # Merge is enabling Merge Keys '<<'
        # https://metacpan.org/pod/YAML::PP::Schema::Merge
        schema => [qw/ + Merge /],

        # Booleans are loaded as JSON::PP::Boolean objects to ensure roundtrips
        boolean => 'JSON::PP',

        # don't print document start marker '---'
        header => 0,

        # explicitly forbid cyclic references
        # When loading untrusted YAML, they can cause memory leaks
        # This will be made fatal in a future version of YAML::PP
        cyclic_refs => 'fatal',
    );
}

sub load_yaml ($type, $input) {
    if ($type eq 'file') {
        return $YP->load_file($input);
    }
    else {
        return $YP->load_string($input);
    }
}

sub dump_yaml (@args) { $YP->dump_string(@args) }

sub validate_data (%args) {
    my $schema_file = $args{schema_file};
    my $data = $args{data};
    my $validate_schema = $args{validate_schema};
    my $validator = JSON::Validator->new;
    my $schema;
    my @errors;

    try {
        # Note: Using the schema filename; slurp'ed text isn't detected as YAML

        unless (-f $schema_file) {
            # JSON::Validator 4.10 reports an unexpected error message for
            # non-existent schema files with absolute paths
            die "Unable to load schema '$schema_file'";
        }
        if ($validate_schema) {
            # Validate the schema: catches errors in type names and definitions
            $validator = $validator->load_and_validate_schema($schema_file);
            $schema = $validator->schema;
        }
        else {
            $schema = $validator->schema($schema_file);
        }
    }
    catch ($e) {
        if ($e =~ m/^YAML::XS::Load Error/) {
            push @errors, $e;
        }
        else {
            # The first line of the backtrace gives us the error message we want
            push @errors, (split /\n/, $e, 2)[0];
        }
    }
    if ($schema) {
        # Note: Don't pass $schema here, that won't work
        push @errors, $validator->validate($data);
    }
    return \@errors;
}

1;
