#!/usr/bin/env perl

# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '10';
use OpenQA::YAML qw(load_yaml validate_data);
use Mojo::File qw(path tempdir tempfile);

my $schema = "$Bin/../public/schema/JobTemplates-01.yaml";
my $template_openqa = "$Bin/data/job-templates/openqa.yaml";
my $template_openqa_null = "$Bin/data/job-templates/openqa-null.yaml";
my $template_openqa_invalid = "$Bin/data/job-templates/openqa-invalid.yaml";
my $template_openqa_dupkey = "$Bin/data/job-templates/duplicate-key.yaml";
my %default_args = (schema_file => $schema);

my $invalid_schema = "$Bin/data/job-templates/schema-invalid.yaml";
my $invalid_yaml_schema = "$Bin/data/job-templates/invalid-yaml-schema.yaml";

my $template = {
    scenarios => {},
    products => {},
};
my $errors = validate_data(%default_args, data => $template,);
is scalar @$errors, 0, "Empty template - no errors";

eval { my $errors = validate_data(schema_file => $invalid_schema, data => $template); };
like($@, qr{JSON::Validator}, "Invalid schema file");

$errors = validate_data(schema_file => 'does-not-exist', data => $template);
is scalar @$errors, 1, "non-existent schema file error" or diag "Error: $_" for @$errors;
like($errors->[0], qr{Unable to load schema}, "non-existent schema file error message");

$errors = validate_data(schema_file => '/does-not-exist', data => $template);
is scalar @$errors, 1, "non-existent absolute schema file error" or diag "Error: $_" for @$errors;
like($errors->[0], qr{Unable to load schema}, "non-existent absolute schema file error message");

$errors = validate_data(schema_file => $invalid_yaml_schema, data => $template);
is scalar @$errors, 1, "Schema file with invalid YAML errors" or diag "Error: $_" for @$errors;
like(
    $errors->[0],
    qr{YAML::XS::Load Error.*document: 1, line: 2, column: 1}s,
    'Schema file with invalid YAML returns full error message'
);

$errors = validate_data(%default_args, data => load_yaml(file => $template_openqa));
if (@$errors) { diag "Error: $_" for @$errors }
is scalar @$errors, 0, "Valid template - no errors";

$errors = validate_data(%default_args, data => load_yaml(file => $template_openqa_null));
if (@$errors) { diag "Error: $_" for @$errors }
is scalar @$errors, 0, "Valid template with testsuite null - no errors";

$errors = validate_data(%default_args, data => load_yaml(file => $template_openqa_invalid));
is scalar @$errors, 1, "Invalid toplevel key detected" or diag "Error: $_" for @$errors;
like($errors->[0], qr{/: Properties not allowed: invalid.}, 'Invalid toplevel key error message');

eval { load_yaml(file => $template_openqa_dupkey) };
my $err = $@;
like($err, qr{Duplicate key 'foo'}, 'Duplicate key detected');

done_testing;
