#!/usr/bin/env perl

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
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use FindBin '$Bin';
use lib "$Bin/lib";
use OpenQA::JobTemplates qw(validate_data);
use Test::More;
use Mojo::File qw(path tempdir tempfile);
use OpenQA::JobTemplates 'load_yaml';

my $schema               = "$Bin/../public/schema/JobTemplates-01.yaml";
my $template_openqa      = "$Bin/data/job-templates/openqa.yaml";
my $template_openqa_null = "$Bin/data/job-templates/openqa-null.yaml";
my %default_args         = (schema_file => $schema);

my $invalid_schema = "$Bin/data/job-templates/schema-invalid.yaml";

my $template = {
    scenarios => {},
    products  => {},
};
my $errors = validate_data(%default_args, data => $template,);
is scalar @$errors, 0, "Empty template - no errors";
eval { my $errors = validate_data(schema_file => $invalid_schema, data => $template); };
like($@, qr{JSON::Validator}, "Invalid schema file");

$errors = validate_data(%default_args, data => load_yaml(file => $template_openqa));
if (@$errors) {
    diag "Error: $_" for @$errors;
}
is scalar @$errors, 0, "Valid template - no errors";

$errors = validate_data(%default_args, data => load_yaml(file => $template_openqa_null));
if (@$errors) {
    diag "Error: $_" for @$errors;
}
is scalar @$errors, 0, "Valid template with testsuite null - no errors";

done_testing;
