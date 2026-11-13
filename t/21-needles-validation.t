#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::MockModule;

my $mock_log;

BEGIN {
    $mock_log = Test::MockModule->new('OpenQA::Log');
    $mock_log->redefine('log_warning', sub { });
}

use OpenQA::Needles::Validation qw(validate_needle_name load_needle_validation_config);
use Mojo::File qw(tempdir);

subtest 'validate_needle_name with timestamp rule' => sub {
    my $rules = 'timestamp';

    is_deeply validate_needle_name('needle-20260813', {}, $rules), [], 'Accept valid YYYYMMDD suffix';
    is_deeply validate_needle_name('needle-20260813_1', {}, $rules), [], 'Accept valid YYYYMMDD_n suffix';
    is_deeply validate_needle_name('needle-20260813-1', {}, $rules), [], 'Accept valid YYYYMMDD-n suffix';
    is_deeply validate_needle_name('needle-20130000', {}, $rules), [], 'Accept valid boundary timestamp 20130000';

    my $errs1 = validate_needle_name('needle-20121231', {}, $rules);
    is scalar(@$errs1), 1, 'Reject year before 2013';
    like $errs1->[0], qr/missing or invalid timestamp suffix/, 'Error message warns about year boundary';

    my $errs2 = validate_needle_name('needle-20260813-sle12', {}, $rules);
    is scalar(@$errs2), 1, 'Reject suffix with non-numeric trailing OS version';
    like $errs2->[0], qr/missing or invalid timestamp suffix/, 'Error message warns about trailing text';

    is_deeply validate_needle_name('needle', {}, $rules),
      [
"Needle 'needle' has missing or invalid timestamp suffix (valid suffixes: -YYYYMMDD or -YYYYMMDD_n with n=0…99) at the end!"
      ], 'Reject needle name with no suffix';

    is_deeply validate_needle_name('needle-abcdefgh', {}, $rules),
      [
"Needle 'needle-abcdefgh' has missing or invalid timestamp suffix (valid suffixes: -YYYYMMDD or -YYYYMMDD_n with n=0…99) at the end!"
      ], 'Reject non-numeric suffix';

    is_deeply validate_needle_name('needle-20260813_100', {}, $rules), [],
      'Accept larger indexes matching python test.py behavior';
};

subtest 'validate_needle_name with workaround_bugref rule' => sub {
    my $rules = 'workaround_bugref';

    is_deeply validate_needle_name('needle', {}, $rules), [], 'Always pass when no properties exist';
    is_deeply validate_needle_name('needle', {properties => []}, $rules), [],
      'Always pass when properties array is empty';
    is_deeply validate_needle_name('needle', {properties => ['some_tag']}, $rules), [],
      'Always pass when workpiece is not tagged workaround';

    my $errs = validate_needle_name('needle-20260813', {properties => ['workaround']}, $rules);
    is scalar(@$errs), 1, 'Reject workaround needle without bugref in name';
    like $errs->[0], qr/includes a workaround tag but has no bug-ID/, 'Error message mentions missing bug-ID';

    is_deeply validate_needle_name('needle-poo12345-20260813', {properties => ['workaround']}, $rules), [],
      'Accept workaround needle with poo bugref';
    is_deeply validate_needle_name('needle-bsc#12345-20260813', {properties => ['workaround']}, $rules), [],
      'Accept workaround needle with bsc bugref';
    is_deeply validate_needle_name('needle-jsc#SLE-12345-20260813', {properties => ['workaround']}, $rules), [],
      'Accept workaround needle with jsc bugref';

    is_deeply validate_needle_name('needle-20260813', {properties => 'workaround'}, $rules),
      ["Needle 'needle-20260813' includes a workaround tag but has no bug-ID in filename!"],
      'Fallback to scalar property check and reject missing bugref';
    is_deeply validate_needle_name('needle-bsc123-20260813', {properties => 'workaround'}, $rules), [],
      'Fallback to scalar property check and accept valid bugref';
};

subtest 'validate_needle_name with single_click_area rule' => sub {
    my $rules = 'single_click_area';

    is_deeply validate_needle_name('needle', {}, $rules), [], 'Pass when area key is missing';
    is_deeply validate_needle_name('needle', {area => []}, $rules), [], 'Pass when area list is empty';
    is_deeply validate_needle_name('needle', {area => [{type => 'match'}]}, $rules), [],
      'Pass when containing only match areas';
    is_deeply validate_needle_name('needle', {area => [{type => 'click'}, {type => 'match'}]}, $rules), [],
      'Pass when containing exactly one click area';

    my $errs = validate_needle_name('needle', {area => [{type => 'click'}, {type => 'click'}]}, $rules);
    is scalar(@$errs), 1, 'Reject when containing multiple click areas';
    like $errs->[0], qr/has 2 areas with type=click/, 'Error message reports number of click areas found';
};

subtest 'load_needle_validation_config from repo' => sub {
    my $instance_config = {
        validation => 'disabled',
        validation_rules => 'timestamp',
    };

    is_deeply load_needle_validation_config(undef, $instance_config),
      {
        validation => 'disabled',
        validation_rules => 'timestamp',
      },
      'Fallback to instance defaults when needledir is undefined';

    is_deeply load_needle_validation_config('/nonexistent', $instance_config),
      {
        validation => 'disabled',
        validation_rules => 'timestamp',
      },
      'Fallback to instance defaults when needledir does not exist';

    my $tempdir = tempdir();
    is_deeply load_needle_validation_config($tempdir->to_string, $instance_config),
      {
        validation => 'disabled',
        validation_rules => 'timestamp',
      },
      'Fallback to instance defaults when no configuration file is present in needledir';

    my $yaml_content = <<'YAML';
validation: block
validation_rules:
  - workaround_bugref
  - single_click_area
YAML
    my $config_file = $tempdir->child('.openqa-needle-validation.yaml');
    $config_file->spew($yaml_content);

    is_deeply load_needle_validation_config($tempdir->to_string, $instance_config),
      {
        validation => 'block',
        validation_rules => 'workaround_bugref,single_click_area',
      },
      'Successfully load validation config with array rules from repo file';

    my $yaml_content2 = <<'YAML';
validation: warn
validation_rules: timestamp,single_click_area
YAML
    $config_file->spew($yaml_content2);

    is_deeply load_needle_validation_config($tempdir->to_string, $instance_config),
      {
        validation => 'warn',
        validation_rules => 'timestamp,single_click_area',
      },
      'Successfully load validation config with comma-separated string rules from repo file';

    my $yaml_content_bad = "validation: :\n  invalid yaml";
    $config_file->spew($yaml_content_bad);

    is_deeply load_needle_validation_config($tempdir->to_string, $instance_config),
      {
        validation => 'disabled',
        validation_rules => 'timestamp',
      },
      'Gracefully fallback to instance defaults when repo configuration file has malformed YAML';
};

done_testing;
